"""Agser platform extensions — OUR code, mounted via aegra.json → http.app.

Endpoints ported from the official LangSmith Agent Server contract
(../agent-server-study/docs/API-SURFACE.md) to close compatibility gaps.
Everything in this file is ours and depends only on pinned public libraries
plus server-core internals (which we own).

Auth here is self-contained: our single-platform-key scheme, verified with
hmac — independent of the core's middleware wiring, so /ok and /metrics can
stay public for health probes while data routes stay protected.

  GET  /ok                       public health probe — {"ok": true} like official
                                 (also in server-core EXEMPT_PATHS — ours)
  GET  /metrics                  Prometheus: process + agser_runs/threads gauges
  POST /threads/count            official count-by-filter (was missing)
  POST /runs/batch               create N background runs in one call
  POST /threads/{id}/copy        copy thread (metadata + current checkpoint)
"""

import hmac
import json
import os
import uuid

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Gauge, generate_latest
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from aegra_api.core.database import db_manager
from aegra_api.core.orm import Run as RunORM
from aegra_api.core.orm import Thread as ThreadORM
from aegra_api.core.orm import get_session
from aegra_api.models import Run, RunCreate, User
from aegra_api.services.run_preparation import _prepare_run

from contextlib import asynccontextmanager


@asynccontextmanager
async def _agser_lifespan(_app):
    """agser (ours): start the CloudWatch backlog-metrics publisher on AWS."""
    _task = None
    if os.environ.get("AGSER_CW_NAMESPACE"):
        import asyncio

        _task = asyncio.get_event_loop().create_task(_cw_publish())
    yield
    if _task is not None:
        _task.cancel()


app = FastAPI(title="agser-platform-extensions", lifespan=_agser_lifespan)

try:
    RUNS_GAUGE = Gauge("agser_runs", "Runs by status", ["status"])
    THREADS_GAUGE = Gauge("agser_threads", "Total threads")
except Exception:  # noqa: BLE001 — already registered on reload
    RUNS_GAUGE = None
    THREADS_GAUGE = None

PLATFORM_USER = User(identity="platform-user", display_name="platform-user")


def require_key(
    x_api_key: str | None = Header(default=None, alias="x-api-key"),
    authorization: str | None = Header(default=None),
) -> User:
    """Self-contained platform-key auth for extension routes."""
    expected = os.environ.get("PLATFORM_API_KEY", "")
    if not expected:
        raise HTTPException(500, "PLATFORM_API_KEY is not configured")
    provided = x_api_key
    if not provided and authorization and " " in authorization:
        provided = authorization.split(" ", 1)[1].strip()
    if not provided or not hmac.compare_digest(provided, expected):
        raise HTTPException(401, "Invalid or missing API key")
    return PLATFORM_USER


@app.get("/ok", tags=["System"])
async def ok() -> dict:
    """Official-compatible public health check."""
    return {"ok": True, "services": {}}


@app.get("/metrics", tags=["System"])
async def metrics(session: AsyncSession = Depends(get_session)) -> Response:
    """Prometheus exposition (process + platform gauges)."""
    if RUNS_GAUGE is not None:
        rows = (await session.execute(select(RunORM.status))).all()
        counts: dict[str, int] = {}
        for (status,) in rows:
            counts[status] = counts.get(status, 0) + 1
        RUNS_GAUGE.clear()
        for status, count in counts.items():
            RUNS_GAUGE.labels(status=status).set(count)
        THREADS_GAUGE.set(
            len((await session.execute(select(ThreadORM.thread_id))).all())
        )
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/threads/count", tags=["Threads"])
async def count_threads(
    request: dict | None = None,
    user: User = Depends(require_key),
    session: AsyncSession = Depends(get_session),
) -> int:
    """Official POST /threads/count — count threads matching a filter.

    Body: {"metadata": {...}, "status": "..."} (both optional), like the
    official search filters. Returns a plain integer (official shape).
    """
    stmt = select(func.count()).select_from(ThreadORM).where(
        ThreadORM.user_id == user.identity
    )
    if request:
        if request.get("status"):
            stmt = stmt.where(ThreadORM.status == request["status"])
        meta = request.get("metadata") or {}
        if meta:
            stmt = stmt.where(
                ThreadORM.metadata_json.contains(meta)  # type: ignore[union-attr]
            )
    (total,) = (await session.execute(stmt)).one()
    return int(total)


class BatchRunItem(BaseModel):
    """One run spec — mirrors official /runs/batch item shape."""

    assistant_id: str
    input: dict | None = None
    thread_id: str | None = None
    metadata: dict | None = None
    config: dict | None = None
    multitask_strategy: str | None = None


@app.post("/runs/batch", tags=["Runs"])
async def batch_runs(
    items: list[BatchRunItem],
    user: User = Depends(require_key),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    """Create N background runs in one call (official /runs/batch).

    Each item creates (or reuses) its thread and enqueues the run; the
    response mirrors the official shape: a list of run records, with a
    per-item {"__error__": ...} object if that item failed.
    """
    results: list[dict] = []
    for item in items:
        try:
            thread_id = item.thread_id
            if not thread_id:
                thread_id = str(uuid.uuid4())
                session.add(
                    ThreadORM(thread_id=thread_id, user_id=user.identity)
                )
                await session.flush()
            request = RunCreate(
                assistant_id=item.assistant_id,
                input=item.input,
                metadata=item.metadata,
                config=item.config,
                multitask_strategy=item.multitask_strategy,
            )
            _rid, run, _job = await _prepare_run(
                session, thread_id, request, user, initial_status="pending"
            )
            results.append(
                run.model_dump(mode="json") if isinstance(run, Run) else dict(run)
            )
        except Exception as exc:  # noqa: BLE001 — official returns per-item errors
            results.append(
                {"__error__": {"error": type(exc).__name__, "message": str(exc)}}
            )
    await session.commit()
    return JSONResponse(results)


@app.post("/threads/{thread_id}/copy", tags=["Threads"])
async def copy_thread(
    thread_id: str,
    user: User = Depends(require_key),
    session: AsyncSession = Depends(get_session),
):
    """Copy a thread — new id, same metadata, current state carried over by
    copying the latest checkpoint tuple to the new thread."""
    source = await session.scalar(
        select(ThreadORM).where(ThreadORM.thread_id == thread_id)
    )
    if source is None:
        return JSONResponse(
            {"detail": f"Thread '{thread_id}' not found"}, status_code=404
        )

    new_id = str(uuid.uuid4())
    session.add(
        ThreadORM(
            thread_id=new_id,
            user_id=source.user_id,
            metadata_json=source.metadata_json,
        )
    )
    await session.flush()

    checkpointer = db_manager.get_checkpointer()
    try:
        config = await checkpointer.aget_config({"configurable": {"thread_id": thread_id}})
        if config:
            from langgraph.checkpoint.base import CheckpointTuple

            tup: CheckpointTuple | None = await checkpointer.aget_tuple(config)
            if tup and tup.checkpoint:
                await checkpointer.aput(
                    {**config, "configurable": {**config.get("configurable", {}), "thread_id": new_id}},
                    tup.checkpoint,
                    tup.metadata,
                    {k: v for k, v in (tup.pending_writes or {}).items()},
                )
    except Exception:  # noqa: BLE001 — copy is best-effort beyond metadata
        pass

    await session.commit()
    return {"thread_id": new_id, "copied_from": thread_id}


# ===========================================================================
# agser (ours): MCP endpoint — official Agent Server contract.
# Streamable HTTP, stateless, POST-only, JSON responses. Every graph becomes
# an MCP tool; input schema from the graph. A paused (human-in-the-loop) run
# returns isError=false with the FULL pending interrupt values plus the exact
# tools/call arguments that resume it, and resuming happens over MCP itself via
# the two reserved arguments below — no REST round-trip needed.
#
# tools/call reserved arguments (stripped before the graph sees them):
#   _thread_id  string    run on an existing thread instead of creating one
#   _resume     any JSON  resume payload for a paused thread; creates the run
#                         with command={"resume": <value>} and no input (the
#                         graph resumes from its checkpoint)
# ===========================================================================
import asyncio
import time as _time

from aegra_api.core.orm import Run as RunORM
from aegra_api.services.assistant_service import _extract_graph_schemas
from aegra_api.services.langgraph_service import get_langgraph_service

MCP_PROTOCOL = "2025-03-26"
MCP_WAIT_SECS = int(os.environ.get("AGSER_MCP_WAIT_SECS", "120"))

# MCP-level control keys — never graph input.
MCP_RESERVED_ARGS = ("_thread_id", "_resume")

_MISSING = object()


def _rpc(id_, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        body["error"] = error
    else:
        body["result"] = result if result is not None else {}
    return JSONResponse(body)


async def _graph_tools() -> list[dict]:
    lg = get_langgraph_service()
    tools = []
    for gid, meta in lg.list_graphs().items():
        desc = ""
        try:
            graph = await lg.get_graph_for_validation(gid, user=PLATFORM_USER)
            schemas = _extract_graph_schemas(graph)
            input_schema = schemas.get("input_schema") or {"type": "object"}
            desc = schemas.get("graph_description") or ""
        except Exception:  # noqa: BLE001 — fall back to a permissive schema
            input_schema = {"type": "object"}
        if isinstance(meta, str):
            desc = desc or meta
        elif isinstance(meta, dict):
            desc = desc or meta.get("description", "")
        tools.append(
            {
                "name": gid,
                "description": desc or f"Run the {gid} agent",
                "inputSchema": input_schema,
            }
        )
    return tools


async def _wait_run(session, run_id: str, wait_secs: int):
    deadline = _time.monotonic() + wait_secs
    while _time.monotonic() < deadline:
        await asyncio.sleep(0.5)
        row = await session.scalar(select(RunORM).where(RunORM.run_id == run_id))
        if row and row.status in ("success", "error", "timeout", "interrupted"):
            return row
    return None


def _as_list(value) -> list:
    """Normalize an interrupt container (tuple / list / single) to a list."""
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return list(value)
    return [value]


def _interrupt_value(entry):
    """The ``value`` of one interrupt, in whatever form the source handed us.

    Three shapes occur: live ``Interrupt`` objects (raw checkpointer writes),
    serialized ``{"value": ..., "id": ...}`` dicts (the REST/serializer path),
    and already-unwrapped values.
    """
    if isinstance(entry, dict):
        return entry["value"] if "value" in entry else entry
    value = getattr(entry, "value", _MISSING)
    return entry if value is _MISSING else value


def _interrupt_values_from_thread_state(state) -> list:
    """``tasks[].interrupts[].value`` — the REST /threads/{id}/state shape."""
    values: list = []
    for task in getattr(state, "tasks", None) or []:
        if isinstance(task, dict):
            values.extend(_interrupt_value(i) for i in _as_list(task.get("interrupts")))
    if not values:
        values.extend(
            _interrupt_value(i) for i in _as_list(getattr(state, "interrupts", None))
        )
    return values


async def _interrupt_values_from_checkpoint(thread_id: str) -> list:
    """Raw checkpointer fallback: the ``__interrupt__`` pending writes on the
    latest checkpoint — exactly what ``aget_state`` projects into
    ``snapshot.tasks[].interrupts``."""
    try:
        checkpointer = db_manager.get_checkpointer()
        tup = await checkpointer.aget_tuple({"configurable": {"thread_id": thread_id}})
    except Exception:  # noqa: BLE001 — interrupt read is best-effort
        return []
    if tup is None:
        return []
    values: list = []
    for write in getattr(tup, "pending_writes", None) or []:
        try:
            _task_id, channel, value = write
        except (TypeError, ValueError):
            continue
        if channel == "__interrupt__":
            values.extend(_interrupt_value(item) for item in _as_list(value))
    if not values:
        checkpoint = tup.checkpoint if isinstance(tup.checkpoint, dict) else {}
        channel_values = checkpoint.get("channel_values") or {}
        if isinstance(channel_values, dict):
            values.extend(
                _interrupt_value(item)
                for item in _as_list(channel_values.get("__interrupt__"))
            )
    return values


def _interrupt_values_from_output(output) -> list:
    """Last resort: the run's stored output, when it carries the interrupt."""
    if not isinstance(output, dict):
        return []
    for payload in (output, output.get("values")):
        if not isinstance(payload, dict):
            continue
        values = [_interrupt_value(i) for i in _as_list(payload.get("__interrupt__"))]
        values += [_interrupt_value(i) for i in _as_list(payload.get("interrupts"))]
        if values:
            return values
    return []


async def _interrupt_values(session, thread_id: str, user: User) -> list:
    """Pending interrupt values for a thread, read the way REST reads them.

    Preferred route mirrors ``GET /threads/{id}/state``: resolve the thread's
    graph from its metadata, ``aget_state`` through the langgraph service with
    ``access_context="threads.read"``, then the shared ``ThreadStateService``
    conversion (``tasks[].interrupts[].value``). Falls back to the raw
    checkpointer so a paused run is never invisible to the client.
    """
    try:
        from aegra_api.api.threads import thread_state_service
        from aegra_api.services.langgraph_service import create_thread_config

        thread = await session.scalar(
            select(ThreadORM).where(ThreadORM.thread_id == thread_id)
        )
        graph_id = ((thread.metadata_json or {}) if thread is not None else {}).get(
            "graph_id"
        )
        if graph_id:
            config = create_thread_config(thread_id, user)
            async with get_langgraph_service().get_graph(
                graph_id, config=config, access_context="threads.read", user=user
            ) as agent:
                snapshot = await agent.aget_state(config)
            if snapshot is not None:
                values = _interrupt_values_from_thread_state(
                    thread_state_service.convert_snapshot_to_thread_state(
                        snapshot, thread_id
                    )
                )
                if values:
                    return values
    except Exception:  # noqa: BLE001 — fall through to the checkpointer
        pass
    return await _interrupt_values_from_checkpoint(thread_id)


def _with_thread(output: dict, thread_id: str, run_id: str) -> dict:
    """Completed-run payload with the identifiers a client needs to continue.

    The graph output is returned as-is (messages, values, structured_response…)
    plus `thread_id` and `run_id`, so an MCP client can chain calls with
    `_thread_id` even when it did not create the thread itself.
    """
    payload = dict(output) if isinstance(output, dict) else {"output": output}
    payload.setdefault("thread_id", thread_id)
    payload.setdefault("run_id", run_id)
    return payload


def _next_call(tool_name: str, thread_id: str, interrupts: list) -> dict:
    """The exact tools/call arguments that move this thread forward.

    Two gate shapes exist in this repo and they resume differently:
      * graph ``interrupt()`` gates (approval / workflow) resume with the
        decision value itself — ``{"approved": true}``;
      * deepagents ``interrupt_on`` tool-approval gates carry
        ``action_requests`` and resume with ``{"decisions": [...]}``, one
        decision per requested action.
    """
    tool_gate = False
    decisions = 1
    for value in interrupts:
        if isinstance(value, dict) and "action_requests" in value:
            tool_gate = True
            requests = value.get("action_requests")
            if isinstance(requests, list):
                decisions = max(decisions, len(requests))
    if tool_gate:
        resume: dict = {"decisions": [{"type": "approve"} for _ in range(decisions)]}
    else:
        resume = {"approved": True}
    if not interrupts:
        # Nothing pending (e.g. the run was cancelled rather than gated): the
        # thread is still resumable, just with a normal call on it.
        return {
            "name": tool_name,
            "arguments": {
                "_thread_id": thread_id,
                "messages": [{"role": "user", "content": "<next instruction>"}],
            },
        }
    return {"name": tool_name, "arguments": {"_thread_id": thread_id, "_resume": resume}}


def _interrupt_payload(tool_name: str, thread_id: str, run_id: str, interrupts: list) -> dict:
    """MCP result payload for a paused run: full interrupt data + resume call."""
    payload = {
        "thread_id": thread_id,
        "run_id": run_id,
        "status": "interrupted",
        "interrupts": interrupts,
        "resume_hint": json.dumps(_next_call(tool_name, thread_id, interrupts)),
    }
    if not interrupts:
        payload["note"] = (
            "no pending interrupt found on this thread (the run may have been "
            "cancelled); continue with a normal call on the same thread"
        )
    return payload


@app.post("/mcp", tags=["MCP"])
async def mcp(
    request: dict,
    user: User = Depends(require_key),
    session: AsyncSession = Depends(get_session),
):
    method = request.get("method", "")
    rid = request.get("id")

    if method == "initialize":
        return _rpc(
            rid,
            {
                "protocolVersion": MCP_PROTOCOL,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "agser-platform", "version": "1.0"},
            },
        )
    if str(method).startswith("notifications/"):
        return Response(status_code=202)
    if method == "tools/list":
        return _rpc(rid, {"tools": await _graph_tools()})
    if method == "tools/call":
        params = request.get("params") or {}
        name = params.get("name", "")
        args = params.get("arguments") or {}
        if not isinstance(args, dict):
            return _rpc(
                rid,
                error={"code": -32000, "message": "tools/call arguments must be an object"},
            )
        thread_arg = args.get("_thread_id")
        resuming = "_resume" in args
        graph_args = {k: v for k, v in args.items() if k not in MCP_RESERVED_ARGS}
        if resuming and not thread_arg:
            return _rpc(
                rid,
                error={
                    "code": -32000,
                    "message": (
                        "_resume requires _thread_id: a resume targets an existing "
                        "paused thread"
                    ),
                },
            )
        try:
            if thread_arg:
                thread_id = str(thread_arg)
                exists = await session.scalar(
                    select(ThreadORM.thread_id).where(ThreadORM.thread_id == thread_id)
                )
                if exists is None:
                    return _rpc(
                        rid,
                        error={
                            "code": -32000,
                            "message": (
                                f"Thread '{thread_id}' not found; omit _thread_id to "
                                "start a new thread"
                            ),
                        },
                    )
            else:
                thread_id = str(uuid.uuid4())
                session.add(ThreadORM(thread_id=thread_id, user_id=user.identity))
                await session.flush()
            if resuming:
                # Resume runs read their input from the checkpoint, and RunCreate
                # makes `input` and `command` mutually exclusive — so input stays
                # None and the graph state already holds the conversation.
                input_data = None
                command: dict | None = {"resume": args["_resume"]}
            else:
                input_data = {
                    "messages": graph_args.get("messages")
                    or [{"role": "user", "content": json.dumps(graph_args)}]
                }
                command = None
            run_req = RunCreate(assistant_id=name, input=input_data, command=command)
            run_id, _run, _job = await _prepare_run(
                session, thread_id, run_req, user, initial_status="pending"
            )
            await session.commit()
            row = await _wait_run(session, run_id, MCP_WAIT_SECS)
            if row is None:
                return _rpc(
                    rid,
                    {
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(
                                    {"run_id": run_id, "thread_id": thread_id,
                                     "status": "running",
                                     "note": "poll or resume via the Agent Server API"}
                                )
                            }
                        ],
                        "isError": False,
                    },
                )
            if row.status == "interrupted":
                # Full interrupt payload: read the real checkpoint state the way
                # GET /threads/{id}/state does, so the client can decide.
                interrupts = await _interrupt_values(session, thread_id, user)
                if not interrupts:
                    interrupts = _interrupt_values_from_output(row.output)
                return _rpc(
                    rid,
                    {
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(
                                    _interrupt_payload(name, thread_id, run_id, interrupts)
                                ),
                            }
                        ],
                        "isError": False,
                    },
                )
            if row.status != "success":
                return _rpc(
                    rid,
                    {"content": [{"type": "text", "text": f"run {row.status}"}],
                     "isError": True},
                )
            return _rpc(
                rid,
                {
                    "content": [
                        {"type": "text",
                         "text": json.dumps(_with_thread(
                             row.output if row.output is not None else {},
                             thread_id, run_id))[:60000]}
                    ],
                    "isError": False,
                },
            )
        except Exception as exc:  # noqa: BLE001
            return _rpc(rid, error={"code": -32000, "message": str(exc)})
    return _rpc(rid, error={"code": -32601, "message": f"Method not found: {method}"})


# ===========================================================================
# agser (ours): A2A endpoint — agent card + message/send per assistant.
# ===========================================================================
@app.get("/.well-known/agent-card.json", tags=["A2A"])
async def agent_card(assistant_id: str | None = None, user: User = Depends(require_key)):
    lg = get_langgraph_service()
    graphs = lg.list_graphs()
    gid = assistant_id or (list(graphs.keys())[0] if graphs else "agent")
    desc = graphs.get(gid, "")
    if isinstance(desc, dict):
        desc = desc.get("description", "")
    return {
        "name": f"agser:{gid}",
        "description": desc or f"The {gid} agent",
        "url": f"{os.environ.get('AGSER_PUBLIC_URL', '')}/a2a/{gid}",
        "version": "1.0",
        "capabilities": {"streaming": False},
        "defaultInputModes": ["text"],
        "defaultOutputModes": ["text"],
        "skills": [
            {"id": gid, "name": gid, "description": desc or f"Run the {gid} agent"}
        ],
    }


@app.post("/a2a/{assistant_id}", tags=["A2A"])
async def a2a_send(
    assistant_id: str,
    request: dict,
    user: User = Depends(require_key),
    session: AsyncSession = Depends(get_session),
):
    if request.get("method") != "message/send":
        return _rpc(request.get("id"),
                   error={"code": -32601, "message": "only message/send is supported"})
    msg = (request.get("params") or {}).get("message") or {}
    text_parts = [
        p.get("text", "") for p in msg.get("parts", []) if p.get("kind") == "text"
    ]
    text = "\n".join(t for t in text_parts if t) or "hello"
    try:
        thread_id = str(uuid.uuid4())
        session.add(ThreadORM(thread_id=thread_id, user_id=user.identity))
        await session.flush()
        run_req = RunCreate(
            assistant_id=assistant_id,
            input={"messages": [{"role": "user", "content": text}]},
        )
        run_id, _run, _job = await _prepare_run(
            session, thread_id, run_req, user, initial_status="pending"
        )
        await session.commit()
        row = await _wait_run(session, run_id, MCP_WAIT_SECS)
        out = ""
        if row is not None and row.output is not None:
            values = row.output.get("values") or row.output
            messages = values.get("messages") if isinstance(values, dict) else None
            if messages:
                out = str(messages[-1].get("content", ""))[:60000]
            else:
                out = json.dumps(values)[:60000]
        elif row is not None and row.status == "interrupted":
            out = json.dumps({"status": "interrupted", "thread_id": thread_id})
        return _rpc(
            request.get("id"),
            {
                "result": {
                    "role": "agent",
                    "parts": [{"kind": "text", "text": out or "(no output)"}],
                    "messageId": str(uuid.uuid4()),
                    "taskId": run_id,
                }
            },
        )
    except Exception as exc:  # noqa: BLE001
        return _rpc(request.get("id"), error={"code": -32000, "message": str(exc)})


# ===========================================================================
# agser (ours): backlog-metrics publisher + OTLP tracing are wired at the
# environment level (see compose / CDK). This publisher exports the queue
# depth to CloudWatch every 60s when running on AWS, feeding the step-scaling
# policy on pending runs (the PDF §8 "backlog autoscaling" item).
# ===========================================================================
CW_NAMESPACE = os.environ.get("AGSER_CW_NAMESPACE", "")  # e.g. "AgserPlatform"



async def _cw_publish():
    try:
        import boto3
        import urllib.request

        region = os.environ.get("AWS_REGION", "ap-south-1")
        cloudwatch = boto3.Session(region_name=region).client("cloudwatch")
        while True:
            try:
                req = urllib.request.Request("http://127.0.0.1:8123/metrics")
                req.add_header("x-api-key", os.environ.get("PLATFORM_API_KEY", ""))
                with urllib.request.urlopen(req, timeout=10) as resp:
                    text = resp.read().decode()
                pending = running = 0
                for line in text.splitlines():
                    if line.startswith("agser_runs{status="):
                        label = line.split('status="')[1].split('"')[0]
                        value = float(line.rsplit(" ", 1)[1])
                        if label == "pending":
                            pending = value
                        elif label == "running":
                            running = value
                cloudwatch.put_metric_data(
                    Namespace=CW_NAMESPACE,
                    MetricData=[
                        {"MetricName": "PendingRuns", "Value": pending,
                         "Unit": "Count"},
                        {"MetricName": "RunningRuns", "Value": running,
                         "Unit": "Count"},
                    ],
                )
            except Exception:  # noqa: BLE001 — never crash the server
                pass
            await asyncio.sleep(60)
    except ImportError:
        return

