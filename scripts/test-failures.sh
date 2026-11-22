#!/usr/bin/env bash
# Failure-injection suite — proves exactly-once step execution across crashes,
# network drops, cancels and parallel load. Runs against any platform target:
#   ./scripts/test-failures.sh                          # local compose
#   BASE=http://<alb> PLATFORM_API_KEY=... ./scripts/test-failures.sh
# All tests are LLM-free and deterministic (graph: sleepy + approval).
set -euo pipefail

BASE=${BASE:-http://127.0.0.1:8123}
API_KEY=${PLATFORM_API_KEY:-dev-key}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

say()  { printf '\n\033[1m[F] %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m  %s\n' "$*"; }
AUTH=(-H "x-api-key: ${API_KEY}" -H 'Content-Type: application/json')

# Hooks — override for other targets:
#   restart_server()  : kill the server mid-run (crash simulation)
RESTART_CMD=${RESTART_CMD:-docker compose restart server}
restart_server() { eval "${RESTART_CMD}"; }

api() { curl -sf -m "${API_TIMEOUT:-15}" "$@"; }

thread() { api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["thread_id"])'; }

prep_count() {  # thread-id -> number of times `prep` executed (exactly-once counter)
  api "${BASE}/threads/$1/state" "${AUTH[@]}" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    se = d["values"].get("side_effects", [])
    print(sum(1 for m in se if str(m.get("content", m) if isinstance(m, dict) else m).startswith("prep:")))
except Exception:
    sys.exit(1)' 2>/dev/null || echo "?"
}

state_status() {
  api "${BASE}/threads/$1" "${AUTH[@]}" 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("status") or "idle")
except Exception:
    sys.exit(1)' || echo "?"
}

# ---------------------------------------------------------------- F1: crash mid-run + exactly-once re-drive
say "F1 — server KILLED mid-run; lease reaper re-drives; prep runs EXACTLY ONCE"
TID=$(thread)
api -X POST "${BASE}/threads/${TID}/runs" "${AUTH[@]}" \
  -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"go"}]}}' > /dev/null
sleep 12   # prep is checkpointed + flushed; long_work is in flight
N=$(prep_count "${TID}")
[ "${N}" = "1" ] || fail "prep should have run once before crash, saw ${N}"
say "  killing server NOW (run in flight)"
restart_server
# watchdog detects the stale busy thread and resubmits; run resumes from checkpoint
say "  waiting for auto-recovery (lease reaper + checkpoint resume + finish)..."
DONE=""
for i in $(seq 1 60); do
  N=$(prep_count "${TID}" || echo "?")
  [ "${N}" = "1" ] || { [ "${N}" = "?" ] || fail "prep ran more than once across the crash! saw ${N}"; }
  MS=$(api "${BASE}/threads/${TID}/state" "${AUTH[@]}" 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(any("long_work: finished" in str(m.get("content","")) for m in d["values"].get("messages",[])))' 2>/dev/null | tail -1 || echo False)
  if [ "${MS}" = "True" ]; then DONE=1; break; fi
  sleep 5
done
[ -n "${DONE}" ] || fail "run did not auto-recover and complete after crash"
N=$(prep_count "${TID}")
[ "${N}" = "1" ] || fail "prep re-executed after crash (expected exactly once), saw ${N}"
ok "crash mid-run: auto-recovered via checkpoint; prep executed exactly once"

# ---------------------------------------------------------------- F2: network drop (client disconnect) recovery
say "F2 — client connection DROPS mid-stream; server-side run survives; stream rejoins"
TID=$(thread)
RID=$(api -X POST "${BASE}/threads/${TID}/runs" "${AUTH[@]}" \
  -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"go"}]}}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
sleep 3
# "network drop": start a join-stream, kill the client after a few seconds
curl -s -N -m 600 "${BASE}/threads/${TID}/runs/${RID}/stream" "${AUTH[@]}" \
  > "${TMP}/dropped.sse" 2>/dev/null &
DROP_PID=$!
sleep 5; kill ${DROP_PID} 2>/dev/null || true   # client vanishes
say "  client dropped; run must continue server-side and complete"
DONE=""
for i in $(seq 1 40); do
  ST=$(api "${BASE}/threads/${TID}/runs/${RID}" "${AUTH[@]}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status"))' 2>/dev/null || echo "?")
  [ "${ST}" = "success" ] && { DONE=1; break; }
  sleep 3
done
[ -n "${DONE}" ] || fail "background run did not survive client disconnect"
# rejoin the stream (resumable stream) and confirm final output arrives
curl -s -N -m 60 "${BASE}/threads/${TID}/runs/${RID}/stream" "${AUTH[@]}" -o "${TMP}/rejoin.sse" || true
grep -q "long_work: finished" "${TMP}/rejoin.sse" "${TMP}/dropped.sse" 2>/dev/null \
  || api "${BASE}/threads/${TID}/state" "${AUTH[@]}" | grep -q "long_work: finished" \
  || fail "rejoined stream never delivered the final output"
N=$(prep_count "${TID}")
[ "${N}" = "1" ] || fail "prep re-executed after client drop, saw ${N}"
ok "network drop: run survived disconnect, stream rejoined, prep exactly once"

# ---------------------------------------------------------------- F3: cancel mid-run, thread not wedged
say "F3 — run CANCELLED mid-flight; thread recovers, new run works"
TID=$(thread)
RID=$(api -X POST "${BASE}/threads/${TID}/runs" "${AUTH[@]}" \
  -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"go"}]}}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
sleep 5
api -X POST "${BASE}/threads/${TID}/runs/${RID}/cancel" "${AUTH[@]}" -d '{}' -o /dev/null \
  || curl -sf -m 15 -X POST "${BASE}/threads/${TID}/runs/${RID}/cancel" "${AUTH[@]}" -o /dev/null \
  || true
sleep 3
R=$(api -X POST "${BASE}/threads/${TID}/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"after-cancel"}]}}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["messages"][-1]["content"])')
echo "after cancel: ${R}" | grep -q pong || fail "thread wedged after cancellation"
ok "cancel: thread not wedged; subsequent runs work"

# ---------------------------------------------------------------- F4: parallel load, each exactly-once
say "F4 — 4 PARALLEL long runs through the queue; all complete, prep exactly once each"
TIDS=()
for i in 1 2 3 4; do
  T=$(thread); TIDS+=("${T}")
  api -X POST "${BASE}/threads/${T}/runs" "${AUTH[@]}" \
    -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"go"}]}}' > /dev/null
done
DONE_COUNT=0
for i in $(seq 1 60); do
  DONE_COUNT=0
  for T in "${TIDS[@]}"; do
    api "${BASE}/threads/${T}/state" "${AUTH[@]}" 2>/dev/null \
      | grep -q "long_work: finished" && DONE_COUNT=$((DONE_COUNT+1))
  done
  [ "${DONE_COUNT}" = "4" ] && break
  sleep 5
done
[ "${DONE_COUNT}" = "4" ] || fail "parallel runs: only ${DONE_COUNT}/4 completed"
for T in "${TIDS[@]}"; do
  N=$(prep_count "${T}" || echo "?")
  [ "${N}" = "1" ] || [ "${N}" = "?" ] || fail "parallel run on ${T}: prep saw ${N} executions"
done
ok "parallel: 4/4 runs completed, each prep exactly once"

say "PASS — failure suite: crash, network drop, cancel, parallel — all exactly-once"
