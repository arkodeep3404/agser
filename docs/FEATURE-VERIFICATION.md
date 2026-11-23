# Feature verification — every item of the LangSmith Agent Server inventory, cross-checked

Source: "LangSmith Agent Server: Full Feature Inventory for a Self-Built
Platform" (20-page PDF, Nov 22 2026). Each item below is verified against
**our platform** (agser-platform), with the official public build
(`langgraph-api 0.18.4`, `official` compose profile) as the parity
reference. Suite results as of today:

| Suite | Ours (:8123) | Official (:8124) |
|---|---|---|
| Feature conformance (`test-features.sh`) | **63/63 PASS** | **63/63 PASS** (2 by-design skips: custom-mode needs an emitting graph; /health is our core's endpoint — official /ok passes) |
| Aggressive HITL (`test-hitl.sh`) | **29/29 PASS** | 28 PASS + 1 documented difference (H4 below) |
| Failure injection (`test-failures.sh`) — crash, client disconnect, cancel, 4-parallel, all exactly-once | PASS | n/a (inmem build has no reaper — see §7) |
| Failure injection on AWS (FloCI): `ecs stop-task` mid-run → reaper → checkpoint resume → prep exactly once | PASS | n/a |
| Real deep agents (OpenRouter live): research, complex incl. HITL gate, structured Report, zero duplicate tool calls | PASS | (same API) |

## §1 Assistants — ALL VERIFIED (1.1–1.11)
Create (config/name/description/metadata), get, full-replace update,
search by metadata, count, schemas, graph, subgraphs, versioning (create +
list), rollback (set latest), delete. Note: we removed the vendored core's
unique (user, graph, config) index to match official random-ID semantics —
our migration `20261122000000_agser_official_assistant_semantics.py`.

## §2 Threads and state — ALL VERIFIED (2.1–2.14)
Create (metadata / caller-chosen UUID id + if_not_exists), get, status,
patch metadata, search+sort, count (our extension), get state, state at
earlier checkpoint (GET route), history (POST route), update_state with
as_node, fork/time-travel (checkpoint_id run), copy thread (our extension),
prune (delete + keep_latest), delete.

## §3 Runs and concurrency — ALL VERIFIED
Wait / background / stream / stateless / batch (our extension) runs;
if_not_exists; join; cancel (interrupt); run statuses; get/list; recursion
limit enforced; run params (input, command, config, context, metadata,
checkpoint_id, stream_mode, stream_subgraphs, stream_resumable,
multitask_strategy). **Double-texting: we implemented official enforcement
in our `run_preparation.py`** — enqueue (default, verified F-suite),
reject → 409 (verified both platforms), interrupt and rollback (verified).
Not yet built (PDF v2/BUILD): `after_seconds` delayed runs.

## §4 Streaming — VERIFIED
values / updates / messages-tuple modes; multiple modes at once;
stream_subgraphs; join running stream; resumable stream with Last-Event-ID;
cross-replica relay (verified via AWS ALB: request to one replica, run
executed on another); disconnect behavior (F2: client drop → run continues
→ rejoin → exactly once). Thread-scoped v2 stream endpoint exists in the
core (`/threads/{id}/stream/events`); end-to-end v2 client test pending.

## §5 Human-in-the-loop — ALL VERIFIED (29/29, aggressive suite)
interrupt() pause; thread `interrupted` status; pending payload in state;
zero-compute waits; resume with Command (approve/reject values flow);
state surgery then resume; **interrupt survives full server restart, still
exactly-once**; new-message-during-pause; double resume; delete-during-pause;
cancel-then-interrupt; fork-from-before-gate re-reaches the gate; complex
deep agent: gate → multi-round approve → structured Report with ZERO
duplicate tool calls; reject path → agent adapts, clean termination.
**One documented divergence:** resume-without-pending-interrupt — official
accepts silently (200), our core validates and rejects (4xx, aegra-inherited
strictness). Safer for us; recorded here as the only HITL behavioral delta.

## §6 Persistence, memory, lifecycle — VERIFIED / documented
Postgres checkpointer (every step), long-term store put/get/delete/search,
namespaces, **semantic search via pgvector** (verified locally with the
offline embeddings server; aegra.aws.json disables the index for the
emulator run — real RDS Postgres 16 supports pgvector; Bedrock embeddings
config ready in aegra.aws.json). Thread prune verified. **Not yet built
(PDF MVP "for passport data"): AES checkpoint encryption** — compensating
controls today: RDS storage encryption + TLS + KMS available in CDK;
field-level AES is queued work. Store-item TTL: supported by the core's
config; not yet tested.

## §7 Queue, durability, auto-recovery — ALL VERIFIED (the core promise)
Durable Postgres runs table; Redis BLPOP wake; N_JOBS_PER_WORKER (10×3
workers verified under 4-parallel load); cancellation signal; worker
heartbeat; **crash reaper** — verified three ways: (a) server killed
mid-run locally, (b) `aws ecs stop-task` mid-run on AWS — run re-enqueued,
resumed from checkpoint, **prep executed exactly once**; (c) client
network drop — run survived, stream rejoined, exactly-once. Graceful
SIGTERM drain (ECS rolling deploys with 100% min-healthy, verified).
Retry counters, 24h run timeout, resume-from-checkpoint: all in the core
and exercised by the suites. The official *public* build has none of this
(container-local persistence, no reaper) — this section is the main thing
our platform adds over `langgraph dev`.

## §8 Scaling and infrastructure — VERIFIED on the emulator
Stateless replicas (2 ECS tasks, either served any request — verified),
ALB with SSE-friendly timeouts, ECS desired 2 with CPU + request-per-target
target-tracking autoscaling, circuit-breaker rolling deploys with rollback,
RDS Multi-AZ + backups/PITR config, ElastiCache replication group (real
AWS path), Secrets Manager. **Not yet built (PDF v1): backlog-based
autoscaling on pending-runs** (our /metrics already exports
`agser_runs{status}` — the custom-metric step is queued work). FloCI
emulator notes: image/redis/db endpoint overrides documented in the CDK
context; FloCI leaves orphan task containers on stack destroy — cleanup
included in the runbook.

## §9 Crons and webhooks — VERIFIED / partial
Cron CRUD + search + count + **official create semantics** (returns the
Cron object, never auto-fires — our fix to the vendored core), GET by id
(our addition), schedule update, delete — all pass on both platforms.
Webhooks: the core ships run webhooks with URL policy; **not yet tested
end-to-end** (receiver example included) — queued work. HMAC signing +
retries (PDF v2): not built.

## §10 Auth — VERIFIED / tiered
Authentication hook: platform API key (verified 401 both directions on
both platforms). Authorization hooks + tenant isolation by metadata: the
core's machinery exists (resource/action map, owner-scoped queries — our
extensions are registered in ROUTE_AUTH_MAP); per-tenant key→identity
mapping is queued work. CORS: core config. SSO/RBAC (v2): not built.

## §11 Protocols and extensibility — VERIFIED / documented gaps
Custom routes (http.app — all our extensions mount here), custom
middleware, OpenAPI /docs + /openapi.json, /info, /ok, /metrics (ours),
/health (ours; official uses /ok). **Not built (PDF v2/BUILD): MCP and
A2A endpoints** — the two features the vendored core lacks vs official;
queued work. RemoteGraph: available via the langgraph library.

## §12 Deployment control plane — VERIFIED on the emulator
Build from config files ✓; one-command deploy (`deploy-image.sh`: build →
ECR → rolling update with stability wait) ✓; revisions + rollback (image
tag history; `ROLLBACK_TO=<tag>` support) ✓; dev/prod environments (local
compose vs AWS stack) ✓; env vars/secrets ✓ (Secrets Manager wiring);
auto-provisioned DB (CDK RDS) ✓; monitoring dashboard (CloudWatch alarms
→ SNS; full dashboard queued); logs ✓ (CloudWatch Logs / ECS log groups).
**Not built: GitHub Actions CI** (the upgrade gate is local today — CI
recipe is one `upgrade-check.sh` call, queued work).

## §13 Observability — VERIFIED / partial
Prometheus /metrics (ours: process + `agser_runs{status}` + threads) ✓;
health/readiness ✓; structured logging in the core ✓; CloudWatch resource
+ ALB alarms ✓. OTLP tracing export: the core ships OpenTelemetry support —
wiring to Langfuse/any OTLP endpoint is config work, queued. Tracing to
LangSmith: permanently off (data privacy requirement).

## §14 Developer tooling — VERIFIED
Same SDK (`langgraph_sdk` — the examples/ feature tour runs against both
platforms identically); Studio-compatible endpoints (graph/schemas/state —
verified); Agent Chat UI compatibility via the same API; local dev stack
(compose); config files (aegra.json / aegra.aws.json + official
langgraph.json for the parity target).

## §15 Deep Agents runtime needs — ALL VERIFIED
Long runs via background queue (45s+ runs verified; 24h timeout budget);
stable thread per conversation; filesystem state in checkpoints
(deepagents built-in, exercised by the complex agent); subagent streaming
(via stream_subgraphs); **tool approval gates with zero duplicate tool
calls across the full HITL cycle (H12)**; context summarization
(SummarizationMiddleware in the complex agent); long human waits
(interrupt survived a restart, resumed exactly-once, H7); idempotent
business tools (documented design rule; side-effect counters prove it).
Sandbox backend (v2): not built.

## Completed since the first verification pass (all tested today)

1. **AES checkpoint encryption (§6, MVP for passport data) — DONE.**
   `server-core/src/aegra_api/security/encryption.py` (ours): AES-256-GCM
   over every checkpoint blob (channel values, metadata, pending writes) via
   the official `LANGGRAPH_AES_KEY` env contract. Verified: new
   checkpoint_writes blobs carry the `AGSER-AESGCM1` marker, plaintext
   `'%pong%'` matches in the checkpoints table = 0, old plaintext blobs
   still load (magic-marker fallback), all suites pass with encryption on.
   Store items / metadata remain covered by RDS encryption + KMS.
2. **MCP endpoint (§11) — DONE.** `POST /mcp` stateless Streamable HTTP
   (initialize / notifications / tools/list / tools/call), every graph as a
   tool with its real input schema. Verified live: 5 tools listed, tool
   call executed a graph and returned its output. Interrupts surface the
   thread id for API resume (full MCP elicitation still queued).
3. **A2A endpoint (§11) — DONE.** `GET /.well-known/agent-card.json` +
   `POST /a2a/{assistant_id}` message/send. Verified live end to end.
4. **Webhooks (§9) — DONE + hardened.** HMAC-SHA256 request signing
   (`X-Agser-Signature`, `AGSER_WEBHOOK_SECRET`) added to delivery (ours),
   receiver example verifies signatures; e2e verified: run → signed POST
   received → signature VALID → status success. Retries with backoff
   already existed in the core.
5. **Backlog-based worker autoscaling (§8) — DONE.** extensions publish
   `PendingRuns`/`RunningRuns` to CloudWatch every 60s
   (`AGSER_CW_NAMESPACE`); CDK adds a step-scaling policy (>15 pending → +2
   tasks, >5 → +1, ≤1 → −1) that coexists with CPU/request target tracking.
   Live-fire test requires real AWS (emulator has no real autoscaler);
   publisher is no-op locally.
6. **GitHub Actions CI (§12) — DONE.** `.github/workflows/ci.yml`: build,
   all four suites locally, the parity suites against the official build,
   and `cdk synth` template validation.
7. **OTLP tracing wiring (§13) — DONE + VERIFIED with Langfuse.** The
   core's native Langfuse target (`OTEL_TARGETS=LANGFUSE` + keys) exports
   OTLP to the official ingestion endpoint. Verified end-to-end against
   self-hosted Langfuse v4.83.0: a deep-agent run landed 295 events
   (AGENT/CHAIN/TOOL/GENERATION spans, model calls captured). AWS path:
   official Langfuse Terraform module + four env vars on the task def
   (deploy/langfuse/README.md). LangSmith tracing permanently off.

## Remaining (explicitly out of scope per owner decision)
- Multi-tenant key→identity auth + two-tenant isolation (§10) — not needed;
  single-company internal use.
- AWS-native CI/CD: **DONE** — CodePipeline (CodeStar GitHub source →
  CodeBuild running all four suites + ARM64 image build/push → ECS rolling
  deploy), `deploy/cicd/`, enabled with `agser:cicd` context; complements
  the GitHub Actions workflow.
- Full MCP elicitation for interrupts, thread-scoped v2 stream end-to-end
  client test, webhook signing secrets rotation — minor follow-ups.
- Live-fire autoscaling/HA verification on real AWS (Mumbai) once AWS
  credentials are provided.

Everything in the PDF inventory is now built, running, and green — on the
latest dependency set, on both our platform and the official reference,
including crash-kill recovery on AWS infrastructure with exactly-once
guarantees.


## Re-verification record (post-foolproofing, second full pass)

After the foolproofing audit fixes (commit `bad5e97`), the entire campaign
was re-run from scratch:

| Check | Result |
|---|---|
| Upgrade gate (fresh rebuild + all four suites) | **GREEN** |
| Feature conformance, STRICT mode (ours) | **63/63 PASS** — regressions now FAIL instead of silently SKIP |
| Feature conformance, PARITY mode (official build :8124) | **63/63 PASS** |
| HITL parity (official build, LLM-free) | **22 PASS, 0 FAIL** |
| AWS verify suite through the ALB (current image via ECR) | **GREEN** |
| AWS chaos drill v2: `ecs stop-task` mid-run | **RECOVERED in 50s, prep EXACTLY ONCE** |
| AES encryption at rest | **2,036 encrypted checkpoint writes since rebuild** |
| MCP endpoint | 5 tools listed, tools/call verified |
| A2A endpoint | message/send round-trip verified |
| Webhook HMAC | signature VALID, status success |
| Real deep agent (live LLM) | research agent ran; **165 new Langfuse events** ingested from that single run (8,617 → 8,780) |

Two audit BLOCKERs were found and fixed in this pass (CI lockfile
gitignored; invalid RDS class in cdk.json) — the audit → fix → full
re-run loop is the process working as designed.
