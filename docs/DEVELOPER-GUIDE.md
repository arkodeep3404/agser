# Developer guide — every component, in detail

For AI agents continuing this project. Read `AGENTS.md` first.

## 1. The server image

`server/aegra.Dockerfile` builds everything from this repo:

- Installs `server-core/` (our FastAPI server; its `pyproject.toml` pins
  public deps) + `deepagents`, `langchain-anthropic/aws/openai`,
  `cryptography`, `boto3`.
- Copies `aegra.json`, `aegra.aws.json`, `auth.py`, `agents/`,
  `extensions/`.
- Entrypoint: `python -m uvicorn aegra_api.main:app --host 0.0.0.0 --port $PORT`
  (the compose/CDK env selects which config via `AEGRA_CONFIG`).
- `server/Dockerfile` is the **official public build** (langgraph-api
  0.18.4) used only for the `official` parity profile on :8124. Do not
  confuse the two. Its entrypoint (`server/entrypoint.sh`) runs
  `python -m langgraph_api.cli --config langgraph.json --n-jobs-per-worker
  ${N_JOBS_PER_WORKER:-10}` (the `--n-jobs-per-worker` flag is mandatory;
  the CLI ignores the env var and forces 1).
- `server/watchdog.py` is an optional orphan-run re-drive sidecar written
  for the official inmem build; **not needed** with our durable core (the
  lease reaper covers it). Keep for reference only.

## 2. Configuration files

| File | Used by | Contents |
|---|---|---|
| `aegra.json` | local compose | graphs registry (5), `auth.path` → `./auth.py:platform_auth`, `http.app` → `./extensions/app.py:app`, `store.index` (pgvector semantic search, `openai:` provider string + offline fake server via `OPENAI_BASE_URL`), `webhooks.url` policy (allows `host.docker.internal` for the e2e webhook test) |
| `aegra.aws.json` | AWS task def (`AEGRA_CONFIG`) — **real AWS** | same graphs/auth/http; `store.index` uses `bedrock:amazon.titan-embed-text-v2:0` (RDS supports pgvector, embeddings stay in-account) |
| `aegra.aws.emulator.json` | AWS task def on **FloCI** (`-c agser:configFile=...`) | identical but **no** `store.index` — the emulator's RDS image has no `pgvector`, so the index would fail on boot |
| `langgraph.json` | the `official` parity build | same graphs/auth/store for the upstream server on :8124 |

Graph registration supports both `{path, description}` objects and plain
`"./path.py:symbol"` strings; factories export `make(config)` — the server
invokes them per-run so per-assistant `config.configurable.model` overrides
work and bad credentials can't crash boot.

## 3. Environment variables (complete reference)

### Identity & security
- `PLATFORM_API_KEY` — shared API key clients send (`x-api-key` or
  `Authorization: Bearer`). Local default `dev-key`. AWS: Secrets Manager
  `agser/platform-api-key`. `auth.py` 500s if unset (never serve open) and
  401s on mismatch (`hmac.compare_digest`).
- `PLATFORM_API_KEYS` — **optional multi-key mode**: `keyA:alice,keyB:bob`
  (or a JSON object). Each key authenticates as its own identity, and the
  core scopes every resource by `user_id`, so identities are fully isolated
  (tenant-style). Empty = single shared identity (default). Verified by
  `scripts/test-multitenancy.sh`.
- `LANGGRAPH_AES_KEY` — 16/24/32-byte key (or any string, SHA-256-derived)
  enabling AES-256-GCM checkpoint encryption (see §6 AGENTS).
- `AGSER_WEBHOOK_SECRET` — enables `X-Agser-Signature` HMAC-SHA256 on
  webhook deliveries.
- `AGSER_WEBHOOK_SECRET_PREVIOUS` — rotation window: deliveries then also
  carry `X-Agser-Signature-Previous`, so receivers still on the old secret
  keep verifying. See `scripts/rotate-webhook-secret.sh`.

### Datastores
- `DATABASE_URL` (our core) / `DATABASE_URI` (official build) — Postgres.
  In AWS the task def passes `POSTGRES_HOST/PORT/USER/PASSWORD/DATABASE` +
  secrets instead; `POSTGRES_PORT` comes from the RDS endpoint token
  (FloCI proxies on a nonstandard port).
- `REDIS_URL` + `REDIS_BROKER_ENABLED=true` — job queue/pubsub.
  **db index is load-bearing**: compose uses `/0`, FloCI ECS `/1` (see
  AGENTS §9 collision).
- `N_JOBS_PER_WORKER` (default 10) — runs per worker; `WORKER_COUNT` (3)
  — asyncio workers per instance.

### Inference (never hardcoded)
- `MODEL_PROVIDER` — `openrouter` | `bedrock` | `anthropic` (default
  `bedrock` in AWS, `openrouter` locally).
- `OPENROUTER_API_KEY` + `OPENROUTER_MODEL`
  (local default `google/gemini-3.5-flash-lite`).
- `BEDROCK_MODEL_ID` (default
  `anthropic.claude-sonnet-4-5-20250929-v1:0`), `AWS_REGION`.
- `AGENT_MODEL` — direct provider string fallback
  (e.g. `anthropic:claude-sonnet-4-5`).
- Per-assistant override: create an assistant with
  `{"configurable": {"model": "<provider:model>"}}` — factories read it.

### Tracing (Langfuse; LangSmith permanently off)
- `OTEL_TARGETS=LANGFUSE`, `LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY`,
  `LANGFUSE_SECRET_KEY` — OTLP to
  `{base}/api/public/otel/v1/traces`, basic auth. Verified: 295 events
  from one deep-agent run.
- `LANGSMITH_TRACING=false`, `LANGSMITH_API_KEY=dummy` — hard off.

### Store embeddings
- `EMBEDDINGS_PROVIDER` (local: `fake` → offline hashed vectors; the
  compose `fake-embed` service is an OpenAI-compatible server on :8010
  pointed at by `OPENAI_BASE_URL`; AWS: Bedrock via config file).
- The fake server must handle tokenized `input` (list-of-lists) — the
  OpenAI SDK pre-tokenizes; hashing handles both.

### Misc
- `SLEEPY_SECS` (default 45) — the crash-recovery test graph's sleep.
- `AGSER_MCP_WAIT_SECS` (default 120) — MCP tool-call run wait.
- `AGSER_CW_NAMESPACE` — when set (AWS task def sets `AgserPlatform`),
  extensions/app.py publishes `PendingRuns`/`RunningRuns` to CloudWatch
  every 60s (boto3; no-op locally).
- `AGSER_WEBHOOK_SECRET` — webhook HMAC.

## 4. Our endpoints (extensions/app.py)

All mounted via `http.app` in the config; auth via the in-file
`require_key` (self-contained — do NOT switch to the core's
`get_current_user`, it depends on middleware wiring that doesn't cover
custom routes; this bit us once).

| Endpoint | Notes |
|---|---|
| `GET /ok` | public health (auth_registry EXEMPT) |
| `GET /metrics` | Prometheus: process gauges + `agser_runs{status}` + `agser_threads` |
| `POST /threads/count` | official count-by-filter (was missing in core) |
| `POST /runs/batch` | official batch create; per-item `__error__` objects |
| `POST /threads/{id}/copy` | metadata + latest checkpoint tuple copy |
| `POST /mcp` | stateless Streamable HTTP: initialize / notifications → 202 / tools/list (one tool per graph, real input schema via `_extract_graph_schemas`) / tools/call. **HITL round-trip**: two reserved arguments — `_thread_id` (continue an existing thread) and `_resume` (the resume payload, e.g. `{"approved": true}` or `{"decisions":[{"type":"approve"}]}`). An interrupted call returns the real interrupt payload, the `thread_id`, the `run_id` and a `resume_hint` showing the exact next call. Completed calls always include `thread_id` + `run_id` so a client can chain calls. |
| `GET /.well-known/agent-card.json` | A2A card (optional `assistant_id` param) |
| `POST /a2a/{assistant_id}` | `message/send` → stateless run → A2A Message reply |
| lifespan `_cw_publish` | backlog metrics publisher (above) |

`_wait_run` polls the runs table every 0.5s up to the wait budget. MCP/A2A
create their own threads per call (stateless semantics).

## 5. The agents (agents/)

| Graph | Purpose | Notes |
|---|---|---|
| `ping` | no-LLM echo | all suites depend on it; handles both dict and message-object inputs |
| `research` | deep agent, factory | tools: catalog lookup; subagent: researcher |
| `complex` | the showcase deep agent, factory | planning, 3 subagents (researcher/analyst/writer), `SummarizationMiddleware(model=model)` (positional `model` arg is REQUIRED in this langchain version), `interrupt_on={"format_report": True}` HITL gate, `response_format=Report` (pydantic) |
| `approval` | deterministic HITL graph | `prep` (side-effect counter → `side_effects` state) → `gate` (`interrupt()`) → `finish`; the exactly-once proof instrument |
| `workflow` | **multi-gate HITL pipeline** (the flagship crash-recovery instrument) | `intake → GATE1 → enrich → GATE2 → execute → GATE3 → report`, plus a `rejected` exit node. Each stage stamps `fx:<stage>:<uuid>` into `side_effects`; each gate is a `interrupt()`; `stage_results` accumulates structured data that must survive crashes. Resume: `{"command":{"resume":{"approved":true|false}}}`. Reject at any gate routes to `rejected` (later stages never run). Covered by `test-workflow.sh` (46 checks) |
| `sleepy` | slow graph for crash tests | `prep` + `sleep(SLEEPY_SECS)`; failure suite F1/F2/F4 depend on it |
| `embeddings.py` | `get_embeddings()` factory | `EMBEDDINGS_PROVIDER`: fake (hashed, offline) / openai / bedrock; all 1024-dim to match config |

**Exactly-once instrumentation**: `approval` and `sleepy` append a
`prep:<uuid>` entry to `state["side_effects"]` each execution; the suites
count those entries — exactly 1 across crash/resume/restart cycles is the
platform's core guarantee. `complex` proves the same via unique
`tool_call_id`s (zero duplicates across HITL resumes).

## 6. Test suites (scripts/)

All take `BASE` (default `http://127.0.0.1:8123`) and
`PLATFORM_API_KEY`; `api()` curls with `API_TIMEOUT` (default 60s, raise
for join/slow ops). All write per-test PASS/FAIL and a SUMMARY; nonzero
exit on any FAIL.

- **verify.sh** — end-to-end smoke incl. SSE stream, background-queue run,
  crons lifecycle (official semantics), store put/search/semantic, metrics
  probe, HITL interrupt→resume with prep-exactly-once assert. Deep-agent
  section skipped unless `ANTHROPIC_API_KEY` set (research agent tested
  manually with OpenRouter).
- **test-features.sh** — ~60 checks against the official inventory; STRICT by default (regression = FAIL), `PARITY=1` for official-build runs (documented divergences stay SKIP); runs
  identically against the official build for parity. Uses UUID thread ids
  (official 422s non-UUID), POST history with limit, `if_not_exists`
  create semantics.
- **test-hitl.sh** — H1–H13 (22 groups, ~30 checks); LLM sections auto-skip with no provider key: every HITL edge case; LLM
  sections gated by `RUN_LLM=1` (default on; CI uses 0);
  `RESTART_CMD` hook points at the right container per target.
- **test-failures.sh** — F1 server-kill (via `RESTART_CMD`), F2 client
  drop + rejoin, F3 cancel-not-wedged, F4 4-parallel — all assert prep
  count exactly 1. Tolerates server-down windows (`?` placeholders).
- **test-workflow.sh** — the multi-gate crash-recovery suite (46 checks,
  W1–W8). Runs against any target; the crash hook is `RESTART_CMD`:
  local = `docker compose restart server`, official = `... official`,
  AWS = `./scripts/aws-restart-tasks.sh`. Env: `BASE`,
  `PLATFORM_API_KEY`, `API_TIMEOUT` (raise to 150 on AWS). W4 is the
  centerpiece: approve gate 1, crash while paused at gate 2, restart,
  assert the thread is still at gate 2 with `side_effects == [intake,
  enrich]` and `stage_results` intact, then resume and assert every stage
  ran exactly once. W6 does three sequential crashes, one per gate.
- **test-v2-stream.sh** — Agent Protocol v2 thread-scoped stream (8 checks).
  Opens `POST /threads/{id}/stream/events` before the run exists, starts the
  run via `POST /threads/{id}/commands` → `run.start`, asserts envelopes
  (`id:` seq + `method`), lifecycle running→completed, payload channels,
  and `since=<seq>` replay. Retries the cycle up to 3× because the v2
  session attaches via a run-lister poll (an instant graph can finish
  between polls).
- **test-multitenancy.sh** — optional multi-key isolation (9 checks).
  SKIPs cleanly unless `PLATFORM_API_KEYS` is set.
- **rotate-webhook-secret.sh** — zero-downtime secret rotation: generates a
  new secret, opens the rotation window in `.env`, prints the AWS steps.
- **check-config-sync.sh** — asserts **all four** config files register the
  same graph set (a drift here silently breaks one target — it caused a
  35-check parity failure once).
- **aws-restart-tasks.sh** — the AWS crash hook: stops all tasks via the
  ECS API and nudges the reconciler (never `docker restart`).
- **upgrade-check.sh** — the gate: rebuild (`docker compose build server`)
  → force-recreate → reconcile the whole stack → wait for `/ok` → run
  config-sync + verify + features + failures + HITL + workflow.
  `--no-rebuild` to gate an already-running server.

## 7. AWS infra (deploy/cdk/)

`lib/platform-stack.ts` — VPC (2 AZ, 2 NATs), ECR repo (MUTABLE :latest,
scan-on-push), Secrets (`agser/platform-api-key` generated,
`anthropic-api-key`, `openrouter-api-key`), RDS Postgres 16 (Multi-AZ
default, 7-day PITR, deletion protection), ElastiCache CfnReplicationGroup
(auto-failover, 2 nodes), internet-facing ALB (idle timeout 3600 for SSE,
deregistration delay 3600), ECS Fargate service (ARM64, 1 vCPU/4GB
default, desired 2, circuit-breaker + 100% min-healthy rolling deploys),
autoscaling (CPU 60% + 50 req/target + backlog step scaling on
`AgserPlatform/PendingRuns`), CloudWatch alarms → SNS. Outputs: AlbDns,
EcrRepoUri, ClusterName, ServiceName, secret ARNs.

CDK context (all optional): `certificateArn` (HTTPS), `allowedCidrs`,
`alertEmail`, `modelProvider`, `agentModel`, `bedrockModelId`,
`otelEndpoint`, `agser:cicd`(+`codestarConnectionArn`, `githubOwner`,
`githubRepo`, `githubBranch`), sizing (`desiredCount`, `cpu`,
`memoryMiB`, `dbInstanceClass`, `dbMultiAz`, `redisNodeType`, `maxCapacity`).
**Emulator-only**: `dbPassword` (explicit, so FloCI can boot its RDS
container), `imageUri` (`localhost:5100/...` registry-reachable ref),
`redisUri` (`redis://host.docker.internal:56379/1` — different db!).
For real AWS, omit these three.

`lib/cicd-stack.ts` — optional CodePipeline (see deploy/cicd/README.md).

## 8. CI

- GitHub Actions (`.github/workflows/ci.yml`): build+up, all four suites,
  official parity (features + HITL LLM-free), `cdk synth`.
- AWS-native (deploy/cicd/): CodePipeline source→CodeBuild(ARM64 build,
  ECR push, all four suites, imagedefinitions.json)→ECS rolling deploy.
  Buildspec container name is `server` (matches task def); CodeBuild uses
  QEMU binfmt for ARM64 cross-build.

## 9. Conventions for changes

1. Edit → `./scripts/upgrade-check.sh` green → commit (message style:
   conventional, explains why).
2. New endpoint: add to `extensions/app.py` + auth_registry map/paths;
   cover in `test-features.sh`; document here.
3. New agent: directory under `agents/`, register in **ALL THREE** configs
   (`aegra.json`, `aegra.aws.json`, `langgraph.json`) — `check-config-sync.sh`
   enforces this and is part of the gate. Add tooling tests to the suites if
   it carries platform guarantees. If it has HITL gates, extend
   `test-workflow.sh`.
4. Upgrading server-core from upstream: re-vendor at a new commit, re-apply
   every `agser (ours)` patch (AGENTS §5 table), run the gate. The
   `official` profile must also stay green.
5. Never commit secrets: `.env` is gitignored (OpenRouter key lives there);
   AWS secrets go in Secrets Manager.
6. Touching run claiming? There are **two** claim paths — the reaper
   (`lease_reaper._find_recoverable`) and the Redis-outage fallback
   (`WorkerExecutor._poll_postgres`). Any predicate (e.g. `_not_before` for
   `after_seconds`) must be applied to both.
