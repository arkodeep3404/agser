"""Auto-recovery watchdog: re-drives runs orphaned by task/server failures.

Runs as a small sidecar service (ECS task / compose profile) alongside the
Agent Server. It re-drives runs whose OWNING PROCESS DIED:

  Orphan definition (precise, no false positives):
    a "running" run whose started_at is older than the server process start
    time, or a "pending"/"queued" run created before the process start.
    Only a process restart can produce these — a run that is slow (a long
    tool call, a long superstep) is never touched.

  The server process start time is read from Prometheus
  `process_start_time_seconds` on GET /metrics (a standard metric the
  Agent Server exposes). If unavailable, the watchdog falls back to a
  conservative updated_at staleness heuristic.

On detection it cancels the dead run row and resubmits the run on the same
thread with `input=None`, which makes the LangGraph engine resume from the
thread's last Postgres checkpoint — every super-step that completed before
the failure is never re-executed; the "pathway" continues exactly where it
stopped. A step that was in flight at the moment of death re-runs from its
start on resume (at-least-once at step granularity) — keep tool side effects
idempotent per step, as with any durable-execution engine.

Human-interrupt waits (`interrupted` threads) are left alone; a human must
resume those.
"""

import logging
import os
import re
import sys
import time
import urllib.request
from datetime import datetime, timezone

from langgraph_sdk import get_sync_client

INTERVAL = int(os.environ.get("WATCHDOG_INTERVAL", "60"))
STALE_SECS = int(os.environ.get("WATCHDOG_STALE_SECS", "3600"))  # fallback only
MAX_THREAD_RECOVERIES = int(os.environ.get("WATCHDOG_MAX_ATTEMPTS", "5"))
URL = os.environ.get("WATCHDOG_SERVER_URL", "http://127.0.0.1:8123")
KEY = os.environ.get("PLATFORM_API_KEY", "")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("watchdog")

_proc_start_re = re.compile(
    r"^process_start_time_seconds\s+([0-9.]+)", re.MULTILINE
)


def parse_ts(ts) -> float:
    if not ts:
        return 0.0
    return datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp()


def server_process_start() -> float | None:
    """Epoch seconds of the server process start, from /metrics."""
    try:
        req = urllib.request.Request(f"{URL}/metrics")
        req.add_header("x-api-key", KEY)
        with urllib.request.urlopen(req, timeout=5) as resp:
            m = _proc_start_re.search(resp.read().decode())
            if m:
                return float(m.group(1))
    except Exception as exc:  # noqa: BLE001
        log.warning("could not read server /metrics: %s", exc)
    return None


def is_orphan(run: dict, proc_start: float | None) -> bool:
    """True iff this run's owning process is gone for certain."""
    status = run.get("status")
    started = parse_ts(run.get("started_at"))
    created = parse_ts(run.get("created_at"))
    if proc_start is not None:
        if status == "running":
            return 0 < started < proc_start - 2
        if status in ("pending", "queued"):
            return 0 < created < proc_start - 2
        return False
    # Fallback heuristic (metrics unavailable): very stale busy thread.
    updated = parse_ts(run.get("updated_at"))
    age = datetime.now(timezone.utc).timestamp() - updated
    return age > STALE_SECS and status == "running"


def recover(client, thread: dict, run: dict) -> None:
    """Cancel the dead run row and resubmit; engine resumes from checkpoint."""
    tid = thread["thread_id"]
    rid = run["run_id"]
    assistant = run.get("assistant_id") or run.get("graph_id")
    if not assistant:
        log.warning("run %s has no assistant_id; cannot resume", rid)
        return
    try:
        client.runs.cancel(tid, rid, action="interrupt", wait=True)
    except Exception as exc:  # noqa: BLE001 — best-effort cleanup of dead row
        log.info("cancel of orphaned run %s returned: %s", rid, exc)
    try:
        client.runs.create(tid, assistant, input=None)
        log.warning(
            "RECOVERED: thread %s — orphaned run %s (started before current "
            "server process) cancelled and resubmitted; resuming from last "
            "checkpoint", tid, rid,
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("resubmit for thread %s failed: %s", tid, exc)


def sweep(client) -> None:
    proc_start = server_process_start()
    recoveries: dict[str, int] = {}
    try:
        busy_threads = client.threads.search(limit=250, status="busy")
    except Exception as exc:  # noqa: BLE001
        log.warning("threads.search failed: %s", exc)
        return
    for thread in busy_threads:
        tid = thread["thread_id"]
        try:
            runs = client.runs.list(tid, limit=10)
        except Exception as exc:  # noqa: BLE001
            log.warning("runs.list for %s failed: %s", tid, exc)
            continue
        for run in runs:
            if run.get("status") not in ("pending", "queued", "running"):
                continue
            if is_orphan(run, proc_start):
                if recoveries.get(tid, 0) >= MAX_THREAD_RECOVERIES:
                    log.error(
                        "thread %s exceeded %d recoveries; giving up — check "
                        "server logs", tid, MAX_THREAD_RECOVERIES,
                    )
                    return
                recover(client, thread, run)
                return  # one recovery per sweep; next sweep re-checks
            return  # thread has a live/pending run owned by this process


def main() -> None:
    if not KEY:
        log.error("PLATFORM_API_KEY is not set — watchdog refusing to start")
        sys.exit(1)
    log.info(
        "watchdog up: server=%s interval=%ss", URL, INTERVAL,
    )
    while True:
        try:
            sweep(get_sync_client(url=URL, api_key=KEY))
        except Exception as exc:  # noqa: BLE001 — never die
            log.warning("sweep failed: %s", exc)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
