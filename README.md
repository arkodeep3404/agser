# agser-platform

A self-hosted **Agent Server for deep agents on your own AWS** — the same API
contract as the official LangSmith Agent Server, with durable, exactly-once
execution of long-running agent workflows.

**Everything in this repository is ours to own and maintain.** The server
core is vendored into `server-core/` (Apache-2.0, provenance in
`server-core/NOTICE.md`) and adapted for official compatibility; we take no
runtime dependency on any external project that LangChain can break — the
only framework pieces are the MIT `langgraph` engine and its Postgres
checkpointer, used strictly as libraries.

## Why

The official Agent Server's public build keeps its durable runtime (Postgres
queue, crash recovery) behind a license. `langgraph dev` is not durable
(container-local disk). This platform gives you the official API surface
plus production durability, owned end to end, deployable to your AWS
account (data never leaves it).

## Architecture

```
Studio / SDK / your app
        │  (official Agent Server API contract)
        ▼
 extensions/app.py (ours: /ok, /metrics, /threads/count,
        │           /runs/batch, /threads/{id}/copy)
        ▼
 server-core/ (ours, vendored Apache-2.0 + our patches)
   ├─ FastAPI API layer, SSE streaming (v1 + v2), webhooks, crons
   ├─ Redis BLPOP job queue; workers with lease + 10s heartbeat
   ├─ lease reaper: crashed runs detected + re-enqueued (crash recovery)
   └─ Postgres: runs, threads, assistants, crons, checkpoints
        ▼
 MIT langgraph engine + langgraph-checkpoint-postgres (libraries, pinned)
        ▼
 agents/ (ours)
   ping       no-LLM echo graph — conformance testing
   research   deep agent (factory: per-assistant model config)
   complex    deep agent: planning, 3 subagents, HITL approval gate
              (interrupt_on), SummarizationMiddleware, structured Report
   approval   human-in-the-loop gate graph
   sleepy     slow graph for crash-recovery proofs
```

**Exactly-once semantics:** every graph superstep commits to Postgres before
the next starts. A crashed run resumes from its last checkpoint — completed
steps never re-execute. A step that was in flight at the crash re-runs from
its start (keep business tools idempotent per step, as the official docs
also require).

## Verified (see git log / this session's runs)

| Suite | Scope | Result |
|---|---|---|
| `scripts/verify.sh` | health, auth, threads, sync/stream/bg runs, state, crons, store, semantic search, metrics, HITL | PASS (local **and** through the AWS ALB) |
| `scripts/test-features.sh` | 62-feature official-contract conformance (assistants CRUD+versions, threads, runs incl. double-texting, streaming modes, HITL, store, crons, auth, protocols) | **62/62 PASS** (local and on AWS) |
| `scripts/test-failures.sh` | kill server mid-run, client network drop, cancel, 4-way parallel — all with exactly-once assertions | PASS |
| Real deep agents | research + complex with live LLM via OpenRouter; complex HITL gate interrupt → approve → structured Report, no tool executed twice | PASS |
| AWS kill-task | `aws ecs stop-task` mid-run on the FloCI AWS emulator → ECS replacement + lease reaper + checkpoint resume → **prep executed exactly once** | PASS |
| `scripts/upgrade-check.sh` | rebuild on fresh dependency resolution + all suites | GREEN |

The suites double as the **upgrade gate**: any change to our code or
dependencies must pass all three before it ships. `server/requirements.lock.txt`
records the last-known-good set for rollback reference (not enforced).

## Run it

```bash
cp .env.example .env          # choose MODEL_PROVIDER etc.
docker compose up -d --build  # Postgres 16 (pgvector) + Redis 7 + server
./scripts/verify.sh           # full platform check
BASE=http://127.0.0.1:8124 PLATFORM_API_KEY=dev-key ./scripts/verify.sh  # vs official public build
```

Inference is never hardcoded: `MODEL_PROVIDER` = `openrouter` | `bedrock`
(IAM-based, data stays in-account) | `anthropic` — or any assistant-level
override via `{"configurable": {"model": ...}}` (agents are registered as
factories).

## Deploy to AWS (Mumbai first)

```bash
cd deploy/cdk
cdk bootstrap aws://<account>/ap-south-1
cdk deploy -c certificateArn=<acm-arn>          # HTTPS via ALB
# then per release:
../scripts/deploy-image.sh                      # build → ECR → rolling deploy
```

The stack: ECS Fargate (2→12 tasks on CPU+request autoscaling, circuit-breaker
rollback), ALB (SSE-friendly timeouts), RDS Postgres 16 Multi-AZ (7-day PITR),
ElastiCache Redis replication group, Secrets Manager, CloudWatch alarms → SNS.
Graceful SIGTERM handling returns in-flight runs to the queue; the reaper
recovers them on replacement tasks.

For the local AWS emulator (FloCI): see `docs/` — includes the emulator-only
context flags (`agser:dbPassword`, `agser:imageUri`, `agser:redisUri`) used
in this session's validation.

## Layout

```
server-core/     our server core (vendored + modified — read NOTICE.md)
extensions/      our official-contract extensions
agents/          our graphs (deep agents + test graphs)
auth.py          platform API-key auth (LangGraph SDK Auth)
aegra.json       local config      aegra.aws.json  AWS config
server/          Dockerfiles      examples/  SDK tour, webhook receiver,
                                    fake embeddings server (offline semantic search)
scripts/         verify / test-features / test-failures / upgrade-check /
                 deploy-image / local-up / local-down
deploy/cdk/      AWS infrastructure
docs/           architecture, runbook, feature verification vs the official
```

## Provenance & licensing

- `server-core/`: vendored from aegra (Apache-2.0) at commit
  `2693066413dfafce3fd21bf581f10bd2495b8dd3` with our compatibility patches;
  license kept in `server-core/LICENSE`, modifications marked `agser (ours)`.
- `langgraph`, `langgraph-checkpoint-postgres`, `langgraph-sdk`: MIT, used as
  pinned libraries.
- Design references: the LangSmith Agent Server study (API contract),
  langhost's durable-runtime concept (deliberately NOT a dependency — it
  hooks LangChain server internals that change without notice).
