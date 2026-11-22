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

app = FastAPI(title="agser-platform-extensions")

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
