# Handoff — decision log & bug archaeology

The "why" behind the current shape of the platform, in the order it
happened — the parts that are NOT derivable from the code alone. For AI
agents continuing this project; read after AGENTS.md.

## Decisions and their reasons

1. **Own-the-code architecture.** Evaluated three foundations: the
   official public build (durable runtime is license-gated; inmem build
   keeps state on container-local disk — wiped on container recreation,
   fatal for ECS), langhost (plugs LangChain server internals that change
   without notice; single maintainer; would rot), and the aegra server
   (independent FastAPI implementing the same contract, Apache-2.0).
   Chose: vendor aegra into `server-core/` and own it. The upstream owner
   later granted written permission (Nov 23, 2026) to redistribute under
   MIT for internal company use → the whole repo is now MIT.
2. **Never LangChain internals.** langgraph engine + postgres
   checkpointer are consumed as pinned libraries only. The `official`
   compose profile exists purely as a contract diff target — parity must
   stay green on both.
3. **Factories for agents** (`make(config)`): ChatBedrockConverse
   validates credentials at construction; module-level construction made
   a bad IAM role crash the whole server boot. Factories also give
   per-assistant model overrides.
4. **Exactly-once instrumentation as first-class tests**: `approval` and
   `sleepy` graphs stamp `prep:<uuid>` into `side_effects`; every
   recovery test asserts count==1. `complex` asserts zero duplicate
   `tool_call_id`s across HITL resumes.
5. **License handling history** (don't re-litigate): vendored Apache-2.0
   file was retained as legally required until the owner's MIT grant
   arrived, then removed. The grant record was deliberately taken out of
   the repo per the owner's instruction — **keep the owner's written
   confirmation in company records outside the repo**; it is the evidence
   behind the single root MIT LICENSE.
6. **Multi-tenancy deliberately skipped** (owner decision — internal
   single-company use). The authorization machinery exists in the core
   (ROUTE_AUTH_MAP); a tenant-key→identity map in `auth.py` is the
   natural extension point if ever needed.
7. **Langfuse over LangSmith** for tracing (data privacy: never leave the
   AWS account). Verified end-to-end; v4 is events_only (no legacy traces
   REST endpoint — check ClickHouse `events_core` or the UI).

## Bugs found and fixed (the archaeology)

| Symptom | Root cause | Fix |
|---|---|---|
| Server crash-looped at boot when AWS creds absent | model built at graph-import time | factory agents (above) |
| Suite `prep should have run once, saw 0` | official CLI forces `N_JOBS_PER_WORKER=1`, runs queued 16s+ behind one slot | `--n-jobs-per-worker` in server/entrypoint.sh |
| Watchdog killed live slow runs in a loop | staleness heuristic couldn't distinguish slow-but-alive from dead | replaced by `/metrics` process-start signal; later superseded entirely by the core's lease reaper |
| Runs stuck pending forever, empty `aegra:jobs`, reaper looping | cross-stack Redis queue theft (two stacks sharing one db) | per-stack Redis db (compose /0, ECS /1); kill orphan task containers |
| Auth handler `'dict' object has no attribute 'split'` | aegra calls the handler with `headers` positionally | `authenticate(headers=None, authorization=None)` accepts both dispatch styles |
| Assistants create → conflict on re-runs | unique (user,graph,config) index (official allows many) | migration + ORM change (AGENTS §5) |
| Batch/copy 500s on custom routes | `get_current_user` needs middleware not applied to custom routes | self-contained `require_key` in extensions |
| Cron create fired a run immediately | aegra auto-triggered first run (violates once-only) | official semantics restored (no auto-fire, GET by id added) |
| Feature suite red vs official | non-UUID thread ids (422), GET vs POST history, /health being ours | suite made contract-correct for both targets |
| Langfuse ClickHouse port 8123 | collides with our server port | compose override remaps to 18123 (documented) |
| ECS image pull "no basic auth credentials" | fake ECR host unresolvable / HTTPS-only registry | `agser:imageUri` = `localhost:5100/...` (HTTP allowed for localhost) |
| RDS "database aegra does not exist" | env name is `POSTGRES_DB`, not `POSTGRES_DATABASE`; port from endpoint token | fixed in task def |
| Double-texting accepted (no 409) | core passed the strategy through without enforcing | enforcement in run_preparation (ours) |
| SummarizationMiddleware TypeError | requires positional `model` in this langchain version | pass `model=model` |
| deepagents interrupt resume `'list' object is not subscriptable` / silently ignored | wrong resume shapes | correct shapes: `{"decisions":[{"type":"approve"}]}` (deepagents gates, may need multiple rounds) and `{"approved":true}` (approval graph) |

## Verification history (what "green" meant, when)

- First full green: verify + features (both servers) + failures, locally.
- Then on the FloCI AWS emulator: verify + 63-feature suite through the
  ALB; kill-task chaos drill with exactly-once proof.
- Then: aggressive HITL suite (29 checks) ours + official parity;
  upgrade gate (all four suites) green on a fresh dependency rebuild.
- Then: AES (ciphertext-at-rest verified in Postgres), MCP + A2A live
  calls, webhook HMAC e2e, Langfuse 295-event ingestion, CI/CD stacks
  synth-verified.
- Every one of these is re-runnable from the suites; nothing is trusted
  from history alone.

## Third pass additions (multi-gate HITL + full emulator crash)

**New instrument**: `agents/workflow/agent.py` — `intake → GATE1 → enrich →
GATE2 → execute → GATE3 → report` with a `rejected` exit. Three sequential
`interrupt()` gates, four `fx:<stage>:<uuid>` side-effect markers, and a
`stage_results` channel that accumulates data which must survive crashes.
Resume shape is `{"command":{"resume":{"approved":bool}}}`. This graph
exists specifically to prove the hardest guarantee, not to do real work —
treat it as the platform's crash-recovery test harness.

**New suite**: `scripts/test-workflow.sh` (46 checks, W1–W8). W4 is the
centerpiece ("crash while paused at gate 2, resume from the exact point"),
W6 is three sequential crashes (one per gate).

**Bugs this pass found (all fixed)**:
1. **Config drift** — `workflow` was in `aegra.json`/`aegra.aws.json` but
   missing from `langgraph.json`; the official build rejected it and 35
   parity checks failed with "Invalid assistant". Guard added:
   `scripts/check-config-sync.sh` (now in the gate). **Any new graph must be
   added to all three config files.**
2. **Message-object indexing** — `m["content"]` on `AIMessage` raises
   `'AIMessage' object is not subscriptable`. Use the `_content()` helper.
   This is the third time this class of bug appeared (ping, approval,
   workflow) — always use the helper.
3. **Weak health probe** — `wait_server` checked only `/ok`; a restarted
   target can serve it before the ALB registers the task or before the DB
   pool is ready. Now polls an authenticated `/threads/{id}` call, and
   status assertions poll for the expected state.
4. **FloCI image caching + no cold-start reconcile** — pushing `:latest`
   does not update running tasks (use immutable tags), and after an emulator
   restart the service needs `aws ecs update-service --desired-count N` to
   bring tasks back. `scripts/aws-restart-tasks.sh` encodes both.

**Emulator crash proof (manual, reproducible)**: workflow paused at gate 2 →
killed all ECS tasks + `docker stop floci-sim` (platform HTTP 000) →
restarted → thread still `interrupted` at gate 2, `side_effects` still
exactly `[intake, enrich]`, `stage_results` intact → resumed → each
remaining stage ran exactly once → completed. Full steps are in
`docs/RUNBOOK.md` under "Multi-gate HITL crash drill".

## Where the next agent should start

1. `AGENTS.md` §8 queued work (real-AWS deploy, LangSmith license parity
   run, MCP elicitation, v2 stream e2e, `after_seconds`).
2. If touching anything: run `./scripts/upgrade-check.sh` first on the
   untouched tree to confirm your baseline is green, then work, then gate
   again.
3. If a contract question comes up ("what does official do here?"), spin
   the `official` profile and test it — never guess.
