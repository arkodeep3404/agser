# Architecture — how the platform actually works

For AI agents continuing this project. Read `AGENTS.md` first; component
reference is in `docs/DEVELOPER-GUIDE.md`; operations in `docs/RUNBOOK.md`.

## 1. System shape

```
                SDK / Studio / your app / MCP client / A2A peer
                                  │  official Agent Server contract
                                  ▼
                    ALB (SSE-friendly, HTTPS+CIDR-restricted)
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                           ▼
        ECS Fargate task (N, stateless)            ECS Fargate task
        ┌───────────────────────────────┐    ┌──────────────────────┐
        │ uvicorn → aegra_api (FastAPI) │    │  (identical image)  │
        │  + extensions/app.py (ours)   │    └──────────────────────┘
        │  + agents (langgraph graphs)  │
        └───────┬───────────────┬───────┘
                │               │
        Postgres (RDS    Redis (ElastiCache
        Multi-AZ)         replication group)
        runs, threads,    BLPOP job queue,
        assistants,       pub/sub streaming,
        crons,            cancel signals,
        checkpoints,      heartbeats
        store (pgvector)
```

Both pools in one image today (API + workers per task); scaling: CPU
target-tracking + requests-per-target + backlog step-scaling
(`PendingRuns`), coexisting policies — the largest demand wins.

## 2. Request lifecycle (POST /threads/{id}/runs)

1. FastAPI route → `run_preparation._prepare_run`:
   auth → resume-command validation → **double-texting enforcement**
   (ours): thread busy + strategy `reject` → 409; `interrupt`/`rollback`
   → cancel the active run (broker signal), else enqueue → assistant
   resolve (graph factories via `make(config)`) → run row INSERT
   (status `pending`) → RPUSH run_id to Redis `aegra:jobs`.
2. Any instance's worker loop BLPOPs the queue, claims the run
   (Postgres lease, `SKIP LOCKED`), heartbeats every 10s.
3. Worker executes the graph via langgraph with the AsyncPostgresSaver
   checkpointer; every super-step commits a checkpoint (channel values,
   metadata, writes — AES-256-GCM encrypted when `LANGGRAPH_AES_KEY`
   is set). Events publish to Redis pub/sub; any API replica relays SSE
   to attached clients.
4. `interrupt()` (HITL): run finalizes as `interrupted`, thread status
   `interrupted`, pending payload stored in the checkpoint. Zero compute
   while paused. Resume = new run with `command.resume`; engine continues
   from the checkpoint — completed steps never re-run.
5. Finalize: status/output written, webhook delivered (HMAC-signed),
   lease released.

## 3. Crash recovery (the exactly-once machinery)

- Every run row + every checkpoint is durable in Postgres before the next
  step starts.
- Workers heartbeat; a **lease reaper** sweeps for runs whose heartbeat
  lapsed (crashed/killed instance), re-enqueues them; any live worker
  claims, resumes from the last checkpoint.
- **How it is proven** (three layers): (a) `approval`/`sleepy` stamp
  `prep:<uuid>` per execution; (b) `workflow` stamps `fx:<stage>:<uuid>`
  across three sequential HITL gates and four stages, so recovery can be
  verified *per gate*; (c) the suites assert count==1 for every marker
  across crash / restart / full-emulator-outage cycles. `complex` proves the
  same for LLM tool calls via unique `tool_call_id`s.
- Guaranteed effect: each completed super-step runs **exactly once**
  across any number of crashes/restarts. A step in flight at crash time
  re-runs from its start — business tools must be idempotent per step
  (documented in the deep-agents' tool design; the `side_effects`
  counters in the approval/sleepy graphs instrument this guarantee and
  the suites assert count==1 through kill/drop/restart cycles).
- SIGTERM drain: in-flight runs get a grace window, then return to the
  queue; ECS rolling deploys exploit this (min-healthy 100%).

## 4. Why no LangChain-internals coupling

The official server's public build (`langgraph dev` family) executes runs
in-process with container-local persistence — not production-durable —
and its licensed durable runtime is closed. Our core (vendored from the
aegra project, MIT-granted) implements the same public contract with our
own Postgres/Redis/queue/reaper machinery and uses `langgraph` +
`langgraph-checkpoint-postgres` strictly as libraries. Consequence:
LangChain upgrades touch us only through pinned library APIs, and the
`official` compose profile lets us continuously diff our contract
against the real upstream server.

## 5. Streaming

- v1 run streams: `POST /threads/{id}/runs/stream` with `stream_mode`
  (`values`/`updates`/`messages-tuple`/custom, multiple at once),
  `stream_subgraphs` (deep-agent subagent visibility), join-stream on a
  running background run, `stream_resumable` + `Last-Event-ID` replay.
- Workers publish to Redis pub/sub → SSE relay from any replica (no
  sticky sessions). ALB idle timeout 3600 + deregistration delay 3600 so
  long agent responses survive deploys.

## 6. Observability

- OpenTelemetry auto-instrumentation spans every run/LLM/tool call;
  exporter target `LANGFUSE` ships OTLP (basic auth) to self-hosted
  Langfuse — verified end-to-end (295 events, GENERATION spans carry
  model metadata). LangSmith export hard-disabled.
- Prometheus `/metrics` (+ CloudWatch custom metrics for autoscaling).
- Structured JSON logs → CloudWatch Logs (AWS) / docker logs (local).

## 7. Security layers

API-key auth on data routes → per-resource authorization map (core) →
AES-256-GCM checkpoints at rest → RDS-at-rest + TLS + KMS for the rest →
SSRF-controlled, HMAC-signed webhooks → secrets via AWS Secrets Manager →
Langfuse tracing entirely in-account → ALB CIDR-restriction + HTTPS.

## 8. Extension points (where new work goes)

1. New REST surface → `extensions/app.py` (+ auth_registry entries) —
   e.g. full MCP elicitation.
1b. Any new graph → register in **all three** configs (`aegra.json`,
   `aegra.aws.json`, `langgraph.json`); `check-config-sync.sh` enforces it.
2. Core behavior changes → `server-core/` patch, marked `agser (ours)`,
   gate must stay green on BOTH servers.
3. New agents → `agents/` + both configs (aegra.json, aegra.aws.json).
4. Infra → `deploy/cdk/lib/platform-stack.ts` (+ cicd-stack when
   `agser:cicd`).
5. New guarantees → add the test FIRST in the matching suite, then the
   code, then run the upgrade gate.
