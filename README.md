# agser

**A production-grade, self-hosted Agent Server for deep agents — on your own AWS, with the same API contract as the official LangSmith Agent Server.**

Durable execution · exactly-once recovery · human-in-the-loop · MCP · A2A · Agent Protocol v2 · AES-256 encryption at rest · self-hosted Langfuse tracing · MIT licensed.

Built to run **long-running agent workflows persistently on AWS**, survive crashes, and never re-run a completed step. Every claim in this README is backed by an executable suite that ships in this repository.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Architecture](#architecture)
- [The exactly-once guarantee](#the-exactly-once-guarantee)
- [Feature list](#feature-list)
- [Verified state](#verified-state)
- [Quickstart](#quickstart)
- [Running agents](#running-agents)
- [Agents included](#agents-included)
- [API surface](#api-surface)
- [Configuration reference](#configuration-reference)
- [Deploy to AWS](#deploy-to-aws)
- [CI/CD](#cicd)
- [Observability](#observability)
- [Security](#security)
- [Upgrading safely](#upgrading-safely)
- [Repository layout](#repository-layout)
- [Documentation](#documentation)
- [Scope decisions](#scope-decisions)
- [License](#license)

---

## Why this exists

The official LangSmith Agent Server is excellent, but its **durable runtime** — the part that makes runs survive crashes — is license-gated in production. The free local build executes runs in-process with container-local persistence, so state dies with the container. On ECS Fargate, where tasks are ephemeral, that is fatal for long-running agents.

This platform takes a different route:

| | Official public build | **agser** |
|---|---|---|
| API contract | official | **same contract** (verified 1:1 against it) |
| Durable runs (Postgres) | ✗ container-local disk | ✓ |
| Crash recovery / lease reaper | ✗ | ✓ |
| Exactly-once per super-step | ✗ | ✓ |
| Runs on your AWS, data never leaves the account | license-gated | ✓ always |
| MCP · A2A · metrics · batch · v2 protocol | ✓ | ✓ |
| License | Elastic-2.0 / commercial | **MIT** |

The server core is **vendored into this repository and owned here** — no dependency on any third party's release cycle, and no coupling to LangChain's internal server interfaces. The only framework pieces used are the MIT `langgraph` engine and its Postgres checkpointer, consumed strictly as pinned libraries.

---

## Architecture

```
              SDK / Studio / your app / MCP client / A2A peer
                                  │   official Agent Server contract
                                  ▼
                     ALB (SSE-friendly, HTTPS + CIDR-restricted)
                                  │
                 ┌────────────────┴────────────────┐
                 ▼                                 ▼
         ECS Fargate task (N, stateless)   ECS Fargate task
         ┌──────────────────────────────┐
         │ uvicorn → aegra_api (FastAPI)│
         │  + extensions/app.py  (ours) │
         │  + agents/ (langgraph graphs)│
         └──────┬───────────────┬───────┘
                │               │
      Postgres (RDS Multi-AZ)   Redis (ElastiCache)
      runs, threads,            BLPOP job queue, pub/sub
      assistants, crons,        streaming, cancel signals,
      checkpoints (AES-256),    worker heartbeats
      store (pgvector)
```

**Request lifecycle** (`POST /threads/{id}/runs`):

1. API validates auth → enforces the double-texting strategy → resolves the assistant (graph factories) → inserts the run row (`pending`) → `RPUSH` the run id onto the Redis queue. With `after_seconds`, the run is created `pending` with a `_not_before` timestamp and **not** submitted.
2. Any worker `BLPOP`s the queue, claims the run (Postgres lease, `SKIP LOCKED`), heartbeats every 10s.
3. The worker executes the graph via `langgraph` with the Postgres checkpointer; every super-step commits a checkpoint (AES-256-GCM encrypted when a key is set). Events publish to Redis pub/sub; any API replica relays SSE.
4. `interrupt()` finalizes the run as `interrupted`; resume is a new run carrying `command.resume` — the engine continues from the checkpoint.
5. On completion the status/output is written, the webhook fires (HMAC-signed), the lease releases.

---

## The exactly-once guarantee

The platform's core promise, instrumented rather than asserted.

- Every super-step commits to Postgres **before** the next one starts → a completed step is durable and never re-executed.
- Workers heartbeat; a **lease reaper** sweeps for lapsed heartbeats, re-enqueues the run, and any live worker resumes from the last checkpoint.
- A step that was *in flight* at the moment of death re-runs from its start — so business tools must be idempotent per step (the same rule the official docs state).
- SIGTERM drain returns in-flight runs to the queue; ECS rolling deploys use `minHealthyPercent: 100`.

**Three independent instrumentation layers:**

| Instrument | What it counts |
|---|---|
| `approval`, `sleepy` graphs | `prep:<uuid>` per execution → suites assert count == 1 across crashes |
| `workflow` graph | `fx:<stage>:<uuid>` across **three sequential HITL gates and four stages** → per-gate recovery verified |
| `complex` graph | unique `tool_call_id`s → zero duplicate tool calls across HITL resumes |

**The proof that was actually run:**

> Multi-gate workflow paused at gate 2 with `side_effects = [intake, enrich]` → killed **all** ECS tasks *and* stopped the AWS emulator control plane (platform returned HTTP 000) → restarted → thread still `interrupted` at gate 2, `side_effects` still exactly `[intake, enrich]`, `stage_results` intact → resumed → `execute` ran once → gate 3 → `report` ran once → completed.
>
> **Every stage exactly once across a complete environment outage.**

---

## Feature list

### Execution & durability
- Postgres-backed run queue with Redis wake-up (`BLPOP`), `SKIP LOCKED` claiming, per-worker concurrency (`N_JOBS_PER_WORKER`, default 10 × 3 workers).
- Lease + heartbeat + **crash reaper** — automatic recovery, no sidecar.
- Graceful shutdown drain; retry counters; 24h run timeout; recursion-limit enforcement.
- **Delayed runs** (`after_seconds`) honoured by both claim paths (reaper and the Redis-outage Postgres fallback).
- Durable checkpoints per super-step with **AES-256-GCM encryption at rest** (`LANGGRAPH_AES_KEY`), backward-compatible with pre-encryption blobs.

### Agent server API (official contract)
- **Assistants**: create/get/update/delete, search, count, schemas, graph, subgraphs, **versioning + rollback**, full-replace updates.
- **Threads**: create (metadata, caller-chosen UUID, `if_not_exists`), get, patch, search+sort, count, delete, copy, prune.
- **State**: get, state-at-checkpoint, history, update state (`as_node`), fork/time-travel from any checkpoint.
- **Runs**: wait / background / stream / stateless / batch; join; cancel (`interrupt`); list/get/delete; `after_seconds`.
- **Double-texting**: `enqueue` (default), `reject` → 409, `interrupt`, `rollback` — enforced server-side.
- **Streaming**: `values`, `updates`, `messages-tuple`, `custom`, multiple modes at once, `stream_subgraphs`, join-stream, resumable streams (`Last-Event-ID`), cross-replica relay.
- **Agent Protocol v2**: thread-scoped event stream (`POST /threads/{id}/stream/events`) with channel filters, `id:` seq envelopes, `since=` replay, and `run.start` commands (`POST /threads/{id}/commands`).
- **Human-in-the-loop**: `interrupt()` pause, pending payload in state, resume via `Command`, static breakpoints (`interrupt_before/after`), state surgery before resume, zero-compute waits, survives server restarts and full outages.
- **Store**: put/get/delete/search, namespaces, **semantic search** (pgvector; provider-agnostic embeddings — Bedrock, OpenAI, or an offline fake server for CI).
- **Crons**: CRUD + search + count + GET-by-id, thread-bound and stateless, UTC 5-field, official semantics (create never auto-fires a run).

### Protocols & extensions (ours — `extensions/app.py`)
| Endpoint | Purpose |
|---|---|
| `GET /ok` | public health probe (official-compatible) |
| `GET /metrics` | Prometheus: process + `agser_runs{status}` + `agser_threads` |
| `POST /threads/count` | official count-by-filter |
| `POST /runs/batch` | official batch create |
| `POST /threads/{id}/copy` | thread copy incl. latest checkpoint |
| `POST /mcp` | **MCP** Streamable HTTP — `initialize`, `tools/list`, `tools/call`; one tool per graph with its real input schema. **HITL round-trip** via reserved `_thread_id` / `_resume` arguments: an interrupted call returns the interrupt payload, thread/run ids and a `resume_hint` |
| `GET /.well-known/agent-card.json` | **A2A** agent card |
| `POST /a2a/{assistant_id}` | **A2A** `message/send` |

### Auth, security, webhooks
- Platform API-key auth (`x-api-key` or `Authorization: Bearer`), constant-time compare, hard-fail if unset.
- **Optional multi-key isolation** (`PLATFORM_API_KEYS=key:identity`): each key is its own identity, fully isolated by the core's `user_id` scoping. Off by default.
- Webhook delivery with SSRF policy (domain allowlist, loopback/private-IP blocking), **HMAC-SHA256 signing** (`X-Agser-Signature`), retries with backoff, and **zero-downtime secret rotation** (dual signature via `X-Agser-Signature-Previous`).
- Secrets in AWS Secrets Manager; `.env` gitignored.

### Observability
- OpenTelemetry auto-instrumentation of runs, LLM calls and tool calls.
- **Self-hosted Langfuse** export via OTLP (`OTEL_TARGETS=LANGFUSE`) — verified: 295 events from one deep-agent run (AGENT / CHAIN / TOOL / GENERATION spans).
- LangSmith tracing **hard-disabled** (data privacy).
- CloudWatch custom metrics (`PendingRuns`, `RunningRuns`) feeding backlog autoscaling; CloudWatch alarms → SNS.

### Infrastructure
- CDK stack: VPC (2 AZ, per-AZ NAT), ECR, Secrets Manager, RDS Postgres 16 Multi-AZ (7-day PITR), ElastiCache Redis replication group (auto-failover), internet-facing ALB (SSE-friendly timeouts), ECS Fargate (ARM64, circuit-breaker rolling deploys), autoscaling (CPU + requests-per-target + backlog step scaling), CloudWatch alarms → SNS.
- Optional **AWS-native CI/CD**: CodePipeline → CodeBuild (ARM64 build, all suites, ECR push) → ECS rolling deploy.

---

## Verified state

Every row is re-runnable from this repository.

| Suite | Command | Coverage | Result |
|---|---|---|---|
| Config sync | `./scripts/check-config-sync.sh` | all four config files register the same graph set | **PASS** |
| Platform smoke | `./scripts/verify.sh` | health, auth, threads, sync/stream/background runs, state, crons, store + semantic search, `/metrics`, HITL interrupt→resume | **PASS** (local + AWS ALB) |
| Feature conformance | `./scripts/test-features.sh` | ~60 checks across the LangSmith inventory (§1–11, 14). STRICT by default — a regression FAILS; `PARITY=1` keeps documented official divergences as SKIPs | **63/63 ours · 63/63 official · 62/62 AWS** |
| Failure injection | `./scripts/test-failures.sh` | server killed mid-run → reaper → checkpoint resume; client network drop → run survives → stream rejoins; cancel; 4-way parallel — all asserting exactly-once | **PASS** |
| HITL lifecycle | `./scripts/test-hitl.sh` | ~30 checks: pause, approve, reject, restart survival, state surgery, double-resume, delete-during-pause, cancel-then-interrupt, fork-to-gate, complex-agent approve+reject with zero duplicate tool calls | **29/29 ours · 22/22 official** |
| Multi-gate crash-recovery | `./scripts/test-workflow.sh` | **46 checks**: 3 sequential approval gates + 4 instrumented stages; crash-while-paused-at-gate-2, crash mid-stage, 3 sequential crashes, reject-at-each-gate, state surgery, fork | **46/46 local · 46/46 official · 46/46 AWS** |
| Agent Protocol v2 stream | `./scripts/test-v2-stream.sh` | 8 checks: thread-scoped SSE opened before the run, v2-native `run.start`, envelopes + `id:` seq, lifecycle running→completed, payload channels, `since=` replay | **8/8 ours · 8/8 official** |
| Multi-key isolation | `./scripts/test-multitenancy.sh` | 9 checks: two identities, cross-tenant read/search/run/delete denied, unknown key 401 (SKIPs when unconfigured) | **9/9 in multi-key mode** |
| Upgrade gate | `./scripts/upgrade-check.sh` | rebuild with fresh deps + functional readiness probe + all eight suites | **GREEN** |

Also verified independently: **AWS kill-task** (`ecs stop-task` mid-run → reaper → resume → exactly once), the **full emulator crash** above, **AES ciphertext at rest** (encrypted blob markers in Postgres, zero plaintext), **MCP** tools/list + tools/call + interrupt→resume, **A2A** message round-trip, **webhook HMAC** validity plus rotation, and **Langfuse** ingestion.

---

## Quickstart

```bash
git clone https://github.com/arkodeep3404/agser.git && cd agser
cp .env.example .env          # set OPENROUTER_API_KEY for real LLM runs
docker compose up -d --build  # postgres(pgvector) + redis + fake-embeddings + server
./scripts/verify.sh           # must be green
```

Server **http://127.0.0.1:8123** · API docs **/docs** · API key `dev-key`.

Parity target — the official public build on `:8124`:

```bash
docker compose --profile official up -d --build
PARITY=1 BASE=http://127.0.0.1:8124 ./scripts/test-features.sh
```

Local ports: `8123` server · `8124` official · `55432` Postgres · `56379` Redis · `8010` fake embeddings · `9999` webhook receiver.

---

## Running agents

```bash
KEY=dev-key
BASE=http://127.0.0.1:8123

# thread
TID=$(curl -s -X POST $BASE/threads -H "x-api-key: $KEY" \
  -H 'Content-Type: application/json' -d '{}' | jq -r .thread_id)

# run and wait
curl -s -X POST $BASE/threads/$TID/runs/wait -H "x-api-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"assistant_id":"research",
       "input":{"messages":[{"role":"user","content":"What can our billing-api do?"}]}}'

# stream tokens
curl -N -X POST $BASE/threads/$TID/runs/stream -H "x-api-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"hi"}]},
       "stream_mode":["messages-tuple"]}'

# delayed run (starts in 60s)
curl -s -X POST $BASE/threads/$TID/runs -H "x-api-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"later"}]},
       "after_seconds":60}'
```

Python SDK (identical to the official one):

```python
from langgraph_sdk import get_client
client = get_client(url="http://127.0.0.1:8123", api_key="dev-key")

thread = await client.threads.create()
async for chunk in client.runs.stream(
    thread["thread_id"], "research",
    input={"messages": [{"role": "user", "content": "Summarize our CRM access"}]},
):
    print(chunk.event, chunk.data)
```

Human-in-the-loop resume:

```bash
curl -s -X POST $BASE/threads/$TID/runs/wait -H "x-api-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"assistant_id":"approval","command":{"resume":{"approved":true}}}'
```

The same over **MCP** — an interrupted `tools/call` returns the interrupt payload plus a `resume_hint`; continue with the reserved arguments:

```json
{"name": "approval",
 "arguments": {"_thread_id": "<thread>", "_resume": {"approved": true}}}
```

A full feature tour (assistants, versions, streaming modes, store, crons, HITL) is in `examples/client_usage.py`.

---

## Agents included

| Graph | What it is | Why it exists |
|---|---|---|
| `ping` | no-LLM echo graph | every suite's fast path |
| `research` | deep agent (factory): catalog tools + researcher subagent | real-world deep-agent demo |
| `complex` | deep agent: planning, **3 subagents**, `SummarizationMiddleware`, **`interrupt_on` tool-approval gate**, structured `Report` | proves HITL + subagents + zero duplicate tool calls |
| `approval` | deterministic single-gate HITL graph (`prep` → `interrupt` → `finish`) | the exactly-once instrument |
| `workflow` | **multi-gate pipeline**: `intake → GATE1 → enrich → GATE2 → execute → GATE3 → report` (+ `rejected` exit) | proves recovery from the exact point where the human was called |
| `sleepy` | slow graph (`prep` + sleep) | crash / network-drop / parallel recovery tests |

LLM-backed agents are registered as **factories** (`make(config)`), so the model resolves per-run: per-assistant overrides work, and a bad credential fails one run instead of the whole server boot.

Inference is **never hardcoded** — `MODEL_PROVIDER` selects `openrouter`, `bedrock` (IAM-based, data stays in-account) or `anthropic`, or pass `{"configurable":{"model":"provider:model"}}` per assistant.

---

## API surface

```
GET    /ok                                  GET    /info
GET    /health /ready /live                 GET    /metrics
GET    /docs  /openapi.json

POST   /assistants                          POST   /assistants/search
POST   /assistants/count                    GET    /assistants/{id}
PATCH  /assistants/{id}                     DELETE /assistants/{id}
GET    /assistants/{id}/schemas             GET    /assistants/{id}/graph
GET    /assistants/{id}/subgraphs           POST   /assistants/{id}/versions
POST   /assistants/{id}/latest

POST   /threads                             POST   /threads/search
POST   /threads/count                       POST   /threads/prune
GET    /threads/{id}                        PATCH  /threads/{id}
DELETE /threads/{id}                        POST   /threads/{id}/copy
GET    /threads/{id}/state                  POST   /threads/{id}/state
GET    /threads/{id}/state/{checkpoint}     POST   /threads/{id}/state/checkpoint
GET    /threads/{id}/history                POST   /threads/{id}/history
GET    /threads/{id}/stream                 POST   /threads/{id}/stream/events   (v2)
POST   /threads/{id}/commands                                                 (v2)

POST   /threads/{id}/runs                   POST   /threads/{id}/runs/wait
POST   /threads/{id}/runs/stream            GET    /threads/{id}/runs
GET    /threads/{id}/runs/{run_id}          DELETE /threads/{id}/runs/{run_id}
POST   /threads/{id}/runs/{run_id}/cancel   GET    /threads/{id}/runs/{run_id}/join
GET    /threads/{id}/runs/{run_id}/stream
POST   /runs                                POST   /runs/batch
POST   /runs/wait                           POST   /runs/stream
POST   /runs/cancel

POST   /runs/crons                          GET    /runs/crons/{id}
PATCH  /runs/crons/{id}                     DELETE /runs/crons/{id}
POST   /runs/crons/search                   POST   /runs/crons/count
POST   /threads/{id}/runs/crons

PUT    /store/items                         GET    /store/items
DELETE /store/items                         POST   /store/items/search
POST   /store/namespaces

POST   /mcp                                 GET    /.well-known/agent-card.json
POST   /a2a/{assistant_id}
```

---

## Configuration reference

### Identity & security
| Variable | Default | Purpose |
|---|---|---|
| `PLATFORM_API_KEY` | `dev-key` (local) | shared API key clients send; server 500s if unset |
| `PLATFORM_API_KEYS` | — | optional `key:identity,key:identity` → isolated identities |
| `LANGGRAPH_AES_KEY` | dev key (local) | 16/24/32-byte key → AES-256-GCM checkpoint encryption at rest |
| `AGSER_WEBHOOK_SECRET` | — | enables `X-Agser-Signature` HMAC-SHA256 on webhooks |
| `AGSER_WEBHOOK_SECRET_PREVIOUS` | — | rotation window: also sends `X-Agser-Signature-Previous` |

### Datastores
| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Postgres (our core). In AWS: `POSTGRES_HOST/PORT/USER/PASSWORD/DB` + secrets |
| `REDIS_URL`, `REDIS_BROKER_ENABLED` | job queue + pub/sub. **db index is load-bearing** — one db per stack |
| `WORKER_COUNT`, `N_JOBS_PER_WORKER` | asyncio workers per instance (3) × concurrent runs each (10) |

### Inference (choose one — nothing hardcoded)
| Variable | Purpose |
|---|---|
| `MODEL_PROVIDER` | `openrouter` \| `bedrock` \| `anthropic` |
| `OPENROUTER_API_KEY`, `OPENROUTER_MODEL` | OpenRouter (local default) |
| `BEDROCK_MODEL_ID`, `AWS_REGION` | Bedrock via IAM task role — data stays in-account |
| `AGENT_MODEL` | direct provider string, e.g. `anthropic:claude-sonnet-4-5` |

### Tracing / metrics
| Variable | Purpose |
|---|---|
| `OTEL_TARGETS=LANGFUSE`, `LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | OTLP export to self-hosted Langfuse |
| `LANGSMITH_TRACING=false` | hard-disabled (privacy) |
| `AGSER_CW_NAMESPACE` | publishes `PendingRuns`/`RunningRuns` to CloudWatch (AWS) |

### Embeddings
`EMBEDDINGS_PROVIDER` = `fake` (offline, deterministic — used in CI) \| `openai` \| `bedrock`. All emit 1024-dim vectors to match `store.index.dims`.

`.env.example` carries the full annotated list.

---

## Deploy to AWS

### Real AWS (Mumbai-first)

```bash
aws login                              # IAM Identity Center credentials
cd deploy/cdk
cdk bootstrap aws://<ACCOUNT>/ap-south-1
cdk deploy -c certificateArn=<acm-arn>        # HTTPS on the ALB
cd ../..
./scripts/deploy-image.sh                     # build → ECR → rolling deploy
# rollback: ROLLBACK_TO=<git-sha-tag> ./scripts/deploy-image.sh
```

Then set the model secret and verify:

```bash
aws secretsmanager put-secret-value --secret-id agser/openrouter-api-key --secret-string "$KEY"
BASE=http://<AlbDns> PLATFORM_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id agser/platform-api-key --query SecretString --output text) ./scripts/verify.sh
```

CDK context flags: `certificateArn`, `allowedCidrs`, `alertEmail`, `modelProvider`, `agentModel`, `bedrockModelId`, `otelEndpoint`, `configFile` (default `aegra.aws.json` — semantic store index on Bedrock embeddings), sizing (`desiredCount`, `cpu`, `memoryMiB`, `dbInstanceClass`, `dbMultiAz`, `redisNodeType`, `maxCapacity`), and `agser:cicd`.

### Local AWS emulator (FloCI)

Emulator-only flags — never use these in real AWS: `agser:dbPassword`, `agser:imageUri` (an immutable tag on `localhost:5100/...`), `agser:redisUri` (a **different Redis db**), `agser:configFile=aegra.aws.emulator.json` (the emulator's RDS has no `pgvector`, so the store index is omitted). Full walkthrough, quirks and the crash drill: `docs/RUNBOOK.md`.

---

## CI/CD

Both options ship and coexist:

- **GitHub Actions** (`.github/workflows/ci.yml`) — builds the stack, runs every suite, runs the **parity** suites against the official build, validates `cdk synth`.
- **AWS-native** (`deploy/cicd/`) — CodePipeline (CodeStar GitHub source) → CodeBuild (ARM64 image build, ECR push, **all suites**, `imagedefinitions.json`) → ECS rolling deploy. Enable with `-c agser:cicd=true -c agser:codestarConnectionArn=... -c agser:githubOwner=... -c agser:githubRepo=...`.

---

## Observability

Self-hosted Langfuse, in your own AWS — no third-party tracing, ever:

```bash
OTEL_TARGETS=LANGFUSE
LANGFUSE_BASE_URL=http://<your-langfuse>:3000
LANGFUSE_PUBLIC_KEY=pk-...
LANGFUSE_SECRET_KEY=sk-...
```

Exports OTLP to `{base}/api/public/otel/v1/traces`. Verified: one deep-agent run produced **295 events** (AGENT / CHAIN / TOOL / GENERATION spans with model metadata). AWS deployment path and local recipe: `deploy/langfuse/README.md`.

> Langfuse v4 runs in `events_only` mode — inspect traces in the UI or ClickHouse `events_core`, not the retired REST endpoint.

---

## Security

- **API-key auth** on every data route; open routes are exactly `/ok`, `/health`, `/ready`, `/live`, `/metrics`, `/info`, `/docs`, `/openapi.json`.
- **AES-256-GCM** checkpoint encryption at rest (verified ciphertext in Postgres); RDS storage encryption + KMS cover the rest.
- **Secrets** in AWS Secrets Manager, injected into the task; `.env` is gitignored and never committed.
- **Webhooks**: SSRF policy (domain allowlist, loopback/private-IP blocking) + HMAC signatures with rotation support.
- **Tracing**: Langfuse only, inside your account; LangSmith hard-disabled.
- **ALB**: restrict with `-c allowedCidrs=[...]`, terminate HTTPS with `-c certificateArn=...`.

---

## Upgrading safely

```bash
./scripts/upgrade-check.sh      # rebuild with fresh deps + all eight suites
```

That gate is the contract: **nothing ships unless it is green.** It protects against upstream drift, dependency regressions and our own mistakes. It also waits for *functional* readiness (a real store write), because liveness is not readiness.

`scripts/check-config-sync.sh` runs in the gate too — it catches a graph registered in one config but missing from another (a real bug that once caused 35 parity failures).

---

## Repository layout

```
AGENTS.md                 entry point for AI agents taking over this project
README.md                 this file
LICENSE                   MIT
docker-compose.yml        local stack (server :8123, official parity :8124)
server-core/              our server core (vendored + 10 marked patches, MIT)
extensions/app.py         our endpoints: MCP, A2A, metrics, batch, copy, CW publisher
agents/                   ping, research, complex, approval, workflow, sleepy
auth.py                   API-key auth (single or multi-key isolation)
aegra.json                local config
aegra.aws.json            real-AWS config (store index on, Bedrock embeddings)
aegra.aws.emulator.json   FloCI config (no store index — no pgvector there)
langgraph.json            config for the official parity build
server/                   Dockerfiles (ours + official parity), healthcheck, entrypoint
scripts/                  verify · test-features · test-hitl · test-failures ·
                          test-workflow · test-v2-stream · test-multitenancy ·
                          check-config-sync · upgrade-check · aws-restart-tasks ·
                          rotate-webhook-secret · deploy-image · local-up/down
deploy/cdk/               AWS infrastructure (PlatformStack + optional CicdStack)
deploy/cicd/              CodeBuild buildspec + CodePipeline guide
deploy/langfuse/          Langfuse AWS deployment + wiring
examples/                 SDK feature tour, rotation-aware webhook receiver,
                          offline OpenAI-compatible embeddings server
docs/                     ARCHITECTURE · DEVELOPER-GUIDE · RUNBOOK · HANDOFF ·
                          FEATURE-VERIFICATION
.github/workflows/ci.yml  GitHub Actions pipeline
```

---

## Documentation

| Document | Contents |
|---|---|
| **[AGENTS.md](AGENTS.md)** | Entry point: verified-state table, the upgrade-gate rule, repo map, **every server-core patch with file locations**, and the hard-won gotchas |
| **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** | System shape, request lifecycle, crash-recovery machinery, exactly-once proof layers, streaming, security, extension points |
| **[docs/DEVELOPER-GUIDE.md](docs/DEVELOPER-GUIDE.md)** | Every component, complete env-var reference, endpoint/agent reference, all suites in detail, CDK flags, change conventions |
| **[docs/RUNBOOK.md](docs/RUNBOOK.md)** | Local / emulator / real-AWS deploys, upgrade procedure, chaos drills, rotation, multi-key, troubleshooting, security posture |
| **[docs/HANDOFF.md](docs/HANDOFF.md)** | Decision log and bug archaeology — the "why"s that aren't in the code |
| **[docs/FEATURE-VERIFICATION.md](docs/FEATURE-VERIFICATION.md)** | Every LangSmith-inventory item mapped to its verification evidence, across all four verification passes |

---

## Scope decisions

Everything that can be built and verified without your AWS account is built and verified. These are deliberate scope decisions, not pending work:

- **Real-AWS live-fire** (autoscaling, Multi-AZ failover) needs an actual AWS account — the wiring is deployed and synth-verified; only `aws login` is missing. `docs/RUNBOOK.md` has the exact procedure.
- **LangSmith licensed-image parity** — the same suites are ready to run against the licensed production image the moment a key is available.
- **Multi-tenancy is opt-in, off by default.** This is internal company tooling; single-key shared access is the default. Set `PLATFORM_API_KEYS` for per-key isolation.
- **MCP interrupts are client-initiated**, not the MCP *elicitation* primitive: the endpoint is stateless Streamable HTTP, so the server cannot initiate a request back to the client. The round-trip is complete (interrupt payload → `resume_hint` → `_resume`), just client-initiated.
- **The emulator config omits the semantic store index** because FloCI's RDS has no `pgvector`. Real AWS uses `aegra.aws.json` with the index on.

---

## License

**MIT** — see [LICENSE](LICENSE). Copyright (c) 2026 Arkodeep Chatterjee.
