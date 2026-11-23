# AGENTS.md — read this first

You are picking up **agser-platform**: a production-grade, self-hosted
Agent Server for deep agents, owned end-to-end by this company, deployed on
AWS (Mumbai-first), MIT-licensed, and built to be API-compatible with the
official LangSmith Agent Server.

This file is the entry point. Read it fully, then the docs it points to.
Everything here reflects the verified state at the last commit — nothing is
aspirational.

---

## 1. What this is, in one paragraph

A Docker image runs our server core (`server-core/`, a vendored+modified
FastAPI server) which exposes the official Agent Server REST contract
(threads, runs, assistants, crons, store, streaming, HITL) plus our
extensions (MCP, A2A, metrics, batch, thread copy). Graph execution uses
the MIT `langgraph` engine as a **library** (never LangChain server
internals). Runs are durable: every run is a Postgres row, workers claim
via Redis BLPOP with leases + heartbeats, a **lease reaper** recovers
crashed runs, and the engine resumes from the last checkpoint so **completed
steps never re-execute** (exactly-once per super-step). Deep agents
(`agents/complex`, `agents/research`) run with real LLMs (provider chosen
by env, never hardcoded). Infra is CDK: ECS Fargate behind an ALB, RDS
Multi-AZ, ElastiCache, autoscaling (CPU + request-count + backlog step
scaling), alarms. Tracing goes to self-hosted Langfuse (OTLP), never
LangSmith. Everything was validated on the local FloCI AWS emulator,
including killing ECS tasks mid-run.

## 2. Verified state (do not re-verify before changing something; DO re-run the gate after ANY change)

| Suite | Command | Coverage | Last result |
|---|---|---|---|
| Platform smoke | `./scripts/verify.sh` | health, auth, threads, sync/stream/bg runs, state, crons, store+semantic, /metrics, HITL interrupt→resume | PASS (local + through AWS ALB) |
| Feature conformance | `./scripts/test-features.sh` | ~60 numbered checks across the LangSmith inventory (§1–11,14): assistants CRUD/versions/rollback, threads/state/fork/copy/prune, runs incl. double-texting reject 409, streaming modes, HITL, store, crons, auth, protocols. STRICT by default (regressions FAIL; `PARITY=1` keeps documented official divergences as SKIPs) | **ALL PASS on BOTH our server (:8123) and the official public build (:8124)** |
| HITL lifecycle | `./scripts/test-hitl.sh` | 22 test groups (~30 checks): pause, approve, reject, restart survival, state surgery, double-resume, delete-during-pause, cancel, fork-to-gate, complex-agent approve+reject with zero duplicate tool calls | 29/29 ours; official 28/29 (one documented divergence: ours rejects resume-without-interrupt with 4xx, official silently accepts) |
| Failure injection | `./scripts/test-failures.sh` | F1 server-kill mid-run → reaper recovery → prep EXACTLY ONCE; F2 client network drop → run survives → stream rejoins; F3 cancel; F4 4-parallel all exactly-once | PASS |
| Upgrade gate | `./scripts/upgrade-check.sh` | rebuilds image with fresh deps + runs verify + features + failures + HITL | GREEN |

Also verified separately (not in the gate):
- **AWS kill-task**: `aws ecs stop-task` mid-run on FloCI → ECS replacement + reaper + checkpoint resume → prep exactly once (log trail in session history).
- **AWS FULL EMULATOR CRASH (hardest proof)**: multi-gate workflow paused at gate 2 (intake+enrich done) → killed all ECS tasks **and** stopped the FloCI control plane (platform unreachable, HTTP 000) → restarted → thread still `interrupted` at gate 2, `side_effects` still exactly `[intake, enrich]`, 2 `stage_results` preserved → resumed → `execute` ran once → gate 3 → `report` ran once → completed. **Every stage exactly once across a full environment outage.** Then the whole 46-check suite ran green through the ALB (`RESTART_CMD=./scripts/aws-restart-tasks.sh`), and the 62-check feature suite green too.
- **AES encryption at rest**: new `checkpoint_writes.blob` rows carry the `AGSER-AESGCM1` magic; `SELECT count(*) FROM checkpoints WHERE checkpoint::text LIKE '%pong%'` = 0.
- **Webhook HMAC**: e2e with signature-verifying receiver → `X-Agser-Signature: sha256=…` VALID.
- **MCP**: `POST /mcp` initialize/tools/list (5 tools)/tools/call executed a graph.
- **A2A**: agent card + `message/send` round-trip.
- **Langfuse**: deep-agent run → 295 OTel events (AGENT/CHAIN/TOOL/GENERATION spans, `ChatOpenAI` generations) in self-hosted Langfuse v4.83.0.

## 3. The one rule that matters most

**Any change to our code or dependencies must pass `./scripts/upgrade-check.sh`
before it ships.** That gate is the platform's protection against upstream
drift and regressions. If it's red, fix before continuing; do not disable
tests.

Second rule: **never couple to LangChain server internals.** The
`langgraph` engine + `langgraph-checkpoint-postgres` are used strictly as
libraries. The `official` compose profile (upstream public build on :8124)
exists as the parity reference — the feature suite must stay green on both.

## 4. Map of the repository

```
AGENTS.md               ← you are here (entry point)
  (see docs/ for ARCHITECTURE / DEVELOPER-GUIDE / RUNBOOK / HANDOFF)
LICENSE                 ← the ONLY license: standard MIT
README.md               ← human-facing overview + quickstart
docker-compose.yml      ← local stack: postgres(pgvector) redis fake-embed server :8123
                          official profile (parity target) :8124
server-core/            ← OUR server core: vendored FastAPI server + our patches (§5)
server/                 ← Dockerfiles (aegra.Dockerfile = the image; healthcheck/entrypoint/watchdog)
aegra.json              ← local config (graphs, auth, http.app, store index, webhook policy)
aegra.aws.json          ← AWS config (Bedrock embeddings; index disabled for emulator)
auth.py                 ← platform API-key auth (works on both servers)
agents/                 ← ping, research, complex (deep agents), approval, sleepy, embeddings.py
extensions/app.py       ← OUR endpoints: /ok /metrics /threads/count /runs/batch
                          /threads/{id}/copy /mcp /a2a/{id} agent-card + CW publisher
scripts/                ← verify, test-features, test-hitl, test-failures,
                          test-workflow (46-check multi-gate crash suite),
                          check-config-sync, aws-restart-tasks (crash hook),
                          upgrade-check, deploy-image, local-up/down (+logs)
deploy/cdk/             ← AWS infra (PlatformStack) + optional CicdStack (agser:cicd)
deploy/cicd/            ← CodeBuild buildspec + CodePipeline README
deploy/langfuse/        ← Langfuse AWS deployment + wiring guide
examples/               ← SDK feature tour, webhook receiver (HMAC-verifying),
                          fake OpenAI-compatible embeddings server, mock receiver
docs/                   ← FEATURE-VERIFICATION (LangSmith inventory cross-check),
                          ARCHITECTURE, RUNBOOK, DEVELOPER-GUIDE (read next)
.github/workflows/ci.yml← CI: all suites + official parity + cdk synth
.env                    ← local secrets (gitignored): OpenRouter key etc.
.env.example            ← every knob documented (OpenRouter vars included)
server/requirements.lock.txt ← last-known-good dep set (reference only, NOT enforced)
```

## 5. server-core provenance & our patches (every one, exact location)

`server-core/` was vendored from the **aegra** project at commit
`2693066413dfafce3fd21bf581f10bd2495b8dd3`. The upstream owner granted
written permission (Nov 23, 2026) to redistribute under MIT for internal
company use; the whole repo is MIT. Search for the marker
`agser (ours)` to find every patch:

| File | Patch |
|---|---|
| `core/auth_registry.py` | `/ok` added to EXEMPT_PATHS; ROUTE_AUTH_MAP entries for `/threads/count`, `/runs/batch`, `/threads/{thread_id}/copy`, `/mcp`, `/.well-known/agent-card.json`, `/a2a/{assistant_id}` |
| `services/run_preparation.py` | Official double-texting enforcement: `reject`→409, `interrupt`/`rollback`→ cancel active run via `_request_run_interruption` (deferred import — api.runs imports this module) |
| `api/crons.py` | Official cron semantics: create returns the Cron object, NEVER auto-fires the first run; added GET `/runs/crons/{cron_id}` |
| `core/orm.py` + `alembic/versions/20261122000000_agser_official_assistant_semantics.py` | Official assistant-create semantics: unique (user,graph,config) index dropped, non-unique lookup index kept |
| `core/database.py` | AES-256-GCM checkpoint encryption injected via `serde` when `LANGGRAPH_AES_KEY` is set |
| `security/encryption.py` | (new file, ours) Encrypted serializer: magic `AGSER-AESGCM1` + nonce + AESGCM, AAD = type string, backward-compatible loads |
| `services/webhook_delivery.py` | HMAC-SHA256 request signing header `X-Agser-Signature` when `AGSER_WEBHOOK_SECRET` set |

If you re-vendor from upstream, re-apply these and re-diff.

## 6. Run it (local)

```bash
cp .env.example .env          # set OPENROUTER_API_KEY for real LLM runs
docker compose up -d --build
./scripts/verify.sh           # must be green
# parity target (optional):
docker compose --profile official up -d --build   # official public build :8124
BASE=http://127.0.0.1:8124 ./scripts/test-features.sh
```

Ports in use locally: 8123 (our server), 8124 (official), 55432 (pg),
56379 (redis), 8010 (fake embeddings), 9999 (webhook receiver),
3000/9090/18123 (Langfuse stack, if run — see deploy/langfuse/README.md;
Langfuse ClickHouse was remapped to 18123 because 8123 is ours).

## 7. Where to go next

- `docs/DEVELOPER-GUIDE.md` — every module explained, env-var reference,
  how to add agents/endpoints, the test suites in detail.
- `docs/ARCHITECTURE.md` — request lifecycle, durability/recovery
  machinery, scaling, security.
- `docs/RUNBOOK.md` — deploy (local/FloCI/real AWS), upgrade procedure,
  troubleshooting incl. FloCI quirks and the Redis-db collision bug class.
- `docs/FEATURE-VERIFICATION.md` — the full LangSmith-inventory cross-check
  with verification evidence, plus the queued-work list.

## 8. Queued work (pick up here)

1. Real-AWS deploy: needs `aws login` credentials; then
   `cdk deploy` + `./scripts/deploy-image.sh` (Mumbai). Live-fire the
   backlog autoscaling + Multi-AZ failover there.
2. LangSmith license key (owner will provide): run the same suites against
   the licensed production image for the final side-by-side.
3. Minor: full MCP elicitation for interrupts (currently surfaces thread id
   for API resume); v2 thread-stream e2e client test; webhook secret
   rotation helper; `after_seconds` delayed runs (inventory §3); re-add
   `store.index` to `aegra.aws.json` when deploying to real RDS (pgvector
   exists there; it is absent on FloCI, hence the current omission).
4. Optional: CDK dashboard for the custom metrics; RDS Proxy for pool
   limits at high replica counts.

## 9. Things that bit us — learn from them

- **Redis db collision**: compose server uses Redis db 0, FloCI ECS tasks
  db 1. If two deployments share a Redis db, one stack's workers steal the
  other's jobs via `aegra:jobs` BLPOP and runs wedge in `pending` while the
  reaper loops. Symptom: "Re-enqueueing stuck pending runs" forever +
  empty queue. Fix: separate db per stack, and kill orphaned task
  containers.
- **FloCI quirks**: no in-place VPC updates (destroy+create); RDS endpoint
  is a proxy on a non-5432 port (`POSTGRES_PORT` from endpoint token);
  ElastiCache replication group is not really implemented (use
  `agser:redisUri` override); orphan ECS task containers survive stack
  destroy (kill them); ALB listener runs inside the FloCI container so
  publish port 80 when running it.
- **langgraph `N_JOBS_PER_WORKER`**: the official CLI silently forces 1
  regardless of env — we pass `--n-jobs-per-worker` explicitly in
  `server/entrypoint.sh`.
- **deepagents `interrupt_on`** takes a dict `{"tool": True}`, not a list;
  resume value shape is `{"decisions":[{"type":"approve"}]}` wrapped in
  `command.resume`; the model can re-gate after approval — resume loops.
- **ChatBedrockConverse validates credentials at construction** — hence
  agents are registered as **factories** (`make(config)`), so a bad
  credential fails one run, never server boot.
- **Langfuse v4 is events_only**: legacy `GET /api/public/traces` is gone;
  verify ingestion via ClickHouse (`events_core`) or the UI.
- **Config drift between the three config files** silently breaks one target
  (a graph missing from `langgraph.json` → official build returns "Invalid
  assistant" and 35 parity checks fail). `check-config-sync.sh` now guards
  this — run it after touching any config.
- **FloCI caches images by reference**: pushing a new `:latest` does NOT
  update running tasks. Use an **immutable tag** and redeploy with
  `-c agser:imageUri=localhost:5100/<repo>:<tag>`. Also, FloCI's reconciler
  does not restart tasks after a cold emulator restart — nudge it with
  `aws ecs update-service --desired-count N` (real ECS does this itself).
- **Never `docker restart` ECS tasks on FloCI**: bypassing the ECS API
  leaves the service with no running tasks. Use `scripts/aws-restart-tasks.sh`
  (stop-task + reconcile nudge) as the crash hook.
- **`wait_server` must check an authenticated call**, not just `/ok`: a
  restarted target can serve `/ok` before the ALB registers it or before its
  DB pool is ready. The workflow suite polls a real `/threads/{id}` now.
- **Message objects vs dicts**: langgraph passes `HumanMessage`/`AIMessage`
  objects, not dicts. `state["messages"][-1]["content"]` raises
  `'AIMessage' object is not subscriptable`. Always use the `_content()`
  helper pattern (`agents/ping`, `agents/approval`, `agents/workflow`).
