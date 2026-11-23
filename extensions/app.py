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
# an MCP tool; input schema from the graph. Interrupts are surfaced as
# isError=false payloads with the thread id so the client can resume via the
# REST API (full MCP elicitation is queued work).
# ===========================================================================
import asyncio
import time as _time

from aegra_api.core.orm import Run as RunORM
from aegra_api.services.assistant_service import _extract_graph_schemas
from aegra_api.services.langgraph_service import get_langgraph_service

MCP_PROTOCOL = "2025-03-26"
MCP_WAIT_SECS = int(os.environ.get("AGSER_MCP_WAIT_SECS", "120"))


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
        input_data = {"messages": args.get("messages") or [{"role": "user", "content": json.dumps(args)}]}
        try:
            thread_id = str(uuid.uuid4())
            session.add(ThreadORM(thread_id=thread_id, user_id=user.identity))
            await session.flush()
            run_req = RunCreate(assistant_id=name, input=input_data)
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
                return _rpc(
                    rid,
                    {
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(
                                    {"thread_id": thread_id, "status": "interrupted",
                                     "note": "human approval required; resume via the API"}
                                )
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
                         "text": json.dumps(row.output if row.output is not None
                                            else {"thread_id": thread_id})[:60000]}
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

