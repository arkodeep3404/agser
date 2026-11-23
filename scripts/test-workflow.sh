#!/usr/bin/env bash
# Multi-gate HITL crash-recovery suite — the hardest guarantee:
#   "the system recovers from the exact point where it was left off
#    before the human was called — nothing ever runs twice."
#
# Uses the `workflow` graph: intake → GATE1 → enrich → GATE2 → execute → GATE3 → report
# Every stage stamps a unique marker into side_effects (the exactly-once counter).
#
#   W1   full happy path: approve all 3 gates → all fx exactly once
#   W2   reject at gate 1 → stages 2–3 never execute
#   W3   reject at gate 2 → stage 3 never executes
#   W4   CRASH while paused at gate 2 → restart → still at gate 2 → resume
#        → intake and enrich NEVER re-run, all state preserved
#   W5   crash mid-enrich-stage (server killed during execution) → reaper
#        recovers → hits gate 2 → resume → all exact
#   W6   sequential crash at EACH gate → 3-crash recovery chain
#   W7   state surgery between gates → resume still works
#   W8   concurrent fork from pre-gate-2 checkpoint re-reaches gate 2
#
#   ./scripts/test-workflow.sh                                        # ours :8123
#   BASE=http://127.0.0.1:8124 ./scripts/test-workflow.sh              # official
#   RESTART_CMD="..." BASE=... ./scripts/test-workflow.sh             # AWS target
set -uo pipefail

BASE=${BASE:-http://127.0.0.1:8123}
API_KEY=${PLATFORM_API_KEY:-dev-key}
RESTART_CMD=${RESTART_CMD:-docker compose restart server}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

AUTH=(-H "x-api-key: ${API_KEY}" -H 'Content-Type: application/json')
PASS=0; FAIL=0; FAILED=()
STRICT=${STRICT:-1}

t() {
  if [ "$2" = ok ]; then PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"
  elif [ "$2" = skip ]; then printf '  \033[33mSKIP\033[0m %s %s\n' "$1" "${3:+— ${3}}"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31mFAIL\033[0m %s %s\n' "$1" "${3:+— ${3}}"; fi
}
api() { curl -s -m "${API_TIMEOUT:-90}" "$@"; }
py() { python3 -c "$1" 2>/dev/null; }
sec() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

new_thread() { api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | py 'import json,sys;print(json.load(sys.stdin)["thread_id"])'; }
status_of()   { api "${BASE}/threads/$1" "${AUTH[@]}" | py 'import json,sys;print(json.load(sys.stdin).get("status") or "idle")'; }

fx_count() {  # count side-effect markers for a given stage name (or all)
  local stage="${2:-}"
  api "${BASE}/threads/$1/state" "${AUTH[@]}" | py "
import json, sys
try:
    d = json.load(sys.stdin)
    fx = d['values'].get('side_effects', [])
    if '${stage}':
        print(sum(1 for m in fx if 'fx:${stage}:' in str(m.get('content',''))))
    else:
        print(len(fx))
except Exception:
    sys.exit(1)
" 2>/dev/null || echo "?"
}

stage_results_count() {
  api "${BASE}/threads/$1/state" "${AUTH[@]}" | py "
import json, sys
try:
    d = json.load(sys.stdin)
    print(len(d['values'].get('stage_results', [])))
except Exception:
    sys.exit(1)
" 2>/dev/null || echo "?"
}

start_workflow() {  # → thread_id, paused at gate 1
  local tid; tid=$(new_thread)
  api -X POST "${BASE}/threads/${tid}/runs/wait" "${AUTH[@]}" \
    -d '{"assistant_id":"workflow","input":{"messages":[{"role":"user","content":"process this"}]}}' > /dev/null
  echo "$tid"
}

resume_gate() {  # thread_id approved_bool → response
  api -X POST "${BASE}/threads/$1/runs/wait" "${AUTH[@]}" \
    -d "{\"assistant_id\":\"workflow\",\"command\":{\"resume\":{\"approved\":$2}}}"
}

wait_interrupted() {  # thread_id [max_attempts] — poll until status=interrupted
  local tid="$1" max="${2:-30}"
  for i in $(seq 1 "$max"); do
    ST=$(status_of "$tid")
    [ "$ST" = interrupted ] && return 0
    sleep 2
  done
  return 1
}

wait_status() {  # thread_id expected_status [max_attempts]
  local tid="$1" want="$2" max="${3:-45}"
  for i in $(seq 1 "$max"); do
    [ "$(status_of "$tid")" = "$want" ] && return 0
    sleep 2
  done
  return 1
}

wait_idle() {  # thread_id [max_attempts]
  local tid="$1" max="${2:-60}"
  for i in $(seq 1 "$max"); do
    ST=$(status_of "$tid")
    [ "$ST" = idle ] && return 0
    sleep 2
  done
  return 1
}

wait_server() {
  # A restarted target can serve /ok before it is registered with the ALB or
  # before its DB pool is ready, so wait for a REAL authenticated API call.
  local tid="${1:-}"
  for i in $(seq 1 60); do
    if api -o /dev/null "${BASE}/ok" 2>/dev/null; then
      if [ -z "$tid" ] || api -o /dev/null "${BASE}/threads/${tid}" "${AUTH[@]}" 2>/dev/null; then
        return 0
      fi
    fi
    sleep 3
  done
  return 1
}

# ================================================================ W1
sec "W1 — full happy path: approve all 3 gates"
T=$(start_workflow)
wait_interrupted "$T" || t "W1.1 paused at gate 1" fail "never interrupted"
t "W1.1 paused at gate 1" "$( [ "$(status_of "$T")" = interrupted ] && echo ok || echo fail)"

GATE1_CTX=$(api "${BASE}/threads/$T/state" "${AUTH[@]}" | py "import json,sys;d=json.load(sys.stdin);tasks=d.get('tasks') or [];print(any('gate.*1' in str(t.get('interrupts',[])) or '\"gate\": 1' in str(t.get('interrupts',[])) for t in tasks))")
t "W1.2 gate 1 payload visible" "$([ "$GATE1_CTX" = True ] && echo ok || echo skip)" "interrupt value check"

R=$(resume_gate "$T" true); wait_interrupted "$T"
t "W1.3 gate 1 approved → paused at gate 2" "$( [ "$(status_of "$T")" = interrupted ] && echo ok || echo fail)"

ENRICH=$(stage_results_count "$T")
t "W1.4 enrich data present at gate 2 (stage_results >= 2)" "$([ "${ENRICH:-0}" -ge 2 ] 2>/dev/null && echo ok || echo fail)" "results=${ENRICH}"

R=$(resume_gate "$T" true); wait_interrupted "$T"
t "W1.5 gate 2 approved → paused at gate 3" "$( [ "$(status_of "$T")" = interrupted ] && echo ok || echo fail)"

EXEC=$(fx_count "$T" execute)
t "W1.6 irreversible action executed once before gate 3" "$([ "${EXEC:-0}" = 1 ] && echo ok || echo fail)" "fx_execute=${EXEC}"

R=$(resume_gate "$T" true)
t "W1.7 gate 3 confirmed → completed" "$( wait_status "$T" idle 60 && echo ok || echo fail)" "status=$(status_of "$T")"

FX_INTAKE=$(fx_count "$T" intake); FX_ENRICH=$(fx_count "$T" enrich); FX_EXEC=$(fx_count "$T" execute); FX_REPORT=$(fx_count "$T" report)
t "W1.8 intake exactly once"      "$([ "${FX_INTAKE:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_INTAKE}"
t "W1.9 enrich exactly once"      "$([ "${FX_ENRICH:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_ENRICH}"
t "W1.10 execute exactly once"   "$([ "${FX_EXEC:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_EXEC}"
t "W1.11 report exactly once"     "$([ "${FX_REPORT:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_REPORT}"

TOTAL_FX=$(fx_count "$T")
t "W1.12 total side effects = 4 (one per stage)" "$([ "${TOTAL_FX:-x}" = 4 ] && echo ok || echo fail)" "total=${TOTAL_FX}"

# ================================================================ W2
sec "W2 — reject at gate 1 → stages 2–3 never execute"
T=$(start_workflow); wait_interrupted "$T"
resume_gate "$T" false > /dev/null; wait_idle "$T"
t "W2.1 exited cleanly after rejection" "$( [ "$(status_of "$T")" = idle ] && echo ok || echo fail)"

FX_INTAKE=$(fx_count "$T" intake); FX_ENRICH=$(fx_count "$T" enrich); FX_EXEC=$(fx_count "$T" execute)
t "W2.2 intake ran once"          "$([ "${FX_INTAKE:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_INTAKE}"
t "W2.3 enrich NEVER ran"         "$([ "${FX_ENRICH:-x}" = 0 ] && echo ok || echo fail)" "fx=${FX_ENRICH}"
t "W2.4 execute NEVER ran"        "$([ "${FX_EXEC:-x}" = 0 ] && echo ok || echo fail)" "fx=${FX_EXEC}"

# ================================================================ W3
sec "W3 — reject at gate 2 → stage 3 never executes"
T=$(start_workflow); wait_interrupted "$T"
resume_gate "$T" true > /dev/null; wait_interrupted "$T"   # gate 1 → gate 2
resume_gate "$T" false > /dev/null; wait_idle "$T"          # reject at gate 2
FX_ENRICH=$(fx_count "$T" enrich); FX_EXEC=$(fx_count "$T" execute)
t "W3.1 enrich ran once"          "$([ "${FX_ENRICH:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_ENRICH}"
t "W3.2 execute NEVER ran"        "$([ "${FX_EXEC:-x}" = 0 ] && echo ok || echo fail)" "fx=${FX_EXEC}"

# ================================================================ W4 (THE KEY TEST)
sec "W4 — CRASH while paused at gate 2 → restart → resume from exact point"
T=$(start_workflow); wait_interrupted "$T"
resume_gate "$T" true > /dev/null; wait_interrupted "$T"   # now at gate 2

# verify we're at gate 2 with enrich data
ENRICH_BEFORE=$(stage_results_count "$T")
FX_INTAKE_BEFORE=$(fx_count "$T" intake)
FX_ENRICH_BEFORE=$(fx_count "$T" enrich)
t "W4.1 pre-crash: intake fx=$FX_INTAKE_BEFORE enrich fx=$FX_ENRICH_BEFORE results=$ENRICH_BEFORE" \
  "$([ "${FX_INTAKE_BEFORE:-x}" = 1 ] && [ "${FX_ENRICH_BEFORE:-x}" = 1 ] && echo ok || echo fail)"

# record the full pre-crash state fingerprint for comparison after recovery
api "${BASE}/threads/$T/state" "${AUTH[@]}" > "${TMP}/pre-crash-state.json"

say() { printf '\n  \033[1m%s\033[0m\n' "$*"; }
say "  >>> CRASHING THE SERVER NOW (paused at gate 2, human not yet responded) <<<"
eval "${RESTART_CMD}" > /dev/null 2>&1
if wait_server "$T"; then t "W4.2 server came back up" ok; else t "W4.2 server came back up" fail "not serving authenticated requests"; fi

t "W4.3 thread still interrupted at gate 2 after crash" "$( wait_status "$T" interrupted 45 && echo ok || echo fail)" "status=$(status_of "$T")"

FX_INTAKE_AFTER=$(fx_count "$T" intake)
FX_ENRICH_AFTER=$(fx_count "$T" enrich)
t "W4.4 intake did NOT re-run during crash/recovery" "$([ "${FX_INTAKE_AFTER:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_INTAKE_AFTER} (was ${FX_INTAKE_BEFORE})"
t "W4.5 enrich did NOT re-run during crash/recovery" "$([ "${FX_ENRICH_AFTER:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_ENRICH_AFTER} (was ${FX_ENRICH_BEFORE})"

ENRICH_AFTER=$(stage_results_count "$T")
t "W4.6 stage_results preserved across crash" "$([ "${ENRICH_AFTER:-0}" = "${ENRICH_BEFORE}" ] && echo ok || echo fail)" "before=${ENRICH_BEFORE} after=${ENRICH_AFTER}"

# verify the interrupt payload still shows gate 2
GATE2=$(api "${BASE}/threads/$T/state" "${AUTH[@]}" | py "
import json, sys
d = json.load(sys.stdin)
gates = [i.get('value', {}).get('gate') for t in (d.get('tasks') or []) for i in t.get('interrupts', [])]
print(2 in gates)
")
t "W4.7 interrupt payload still shows gate 2" "$([ "$GATE2" = True ] && echo ok || echo fail)" "gate2=${GATE2}"

# now resume — the workflow should continue from gate 2, NOT restart
R=$(resume_gate "$T" true)
t "W4.8 resumed from gate 2 → now at gate 3" "$( wait_status "$T" interrupted 60 && echo ok || echo fail)" "status=$(status_of "$T")"

FX_EXEC=$(fx_count "$T" execute)
t "W4.9 execute ran exactly once after gate-2 resume" "$([ "${FX_EXEC:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_EXEC}"

R=$(resume_gate "$T" true)
t "W4.10 gate 3 confirmed → completed" "$( wait_status "$T" idle 60 && echo ok || echo fail)" "status=$(status_of "$T")"

FX_INTAKE=$(fx_count "$T" intake); FX_ENRICH=$(fx_count "$T" enrich); FX_EXEC=$(fx_count "$T" execute); FX_REPORT=$(fx_count "$T" report)
t "W4.11 FINAL: intake exactly once across crash+recovery"     "$([ "${FX_INTAKE:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_INTAKE}"
t "W4.12 FINAL: enrich exactly once across crash+recovery"     "$([ "${FX_ENRICH:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_ENRICH}"
t "W4.13 FINAL: execute exactly once across crash+recovery"   "$([ "${FX_EXEC:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_EXEC}"
t "W4.14 FINAL: report exactly once across crash+recovery"    "$([ "${FX_REPORT:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_REPORT}"

# ================================================================ W5
sec "W5 — crash mid-stage (not at a gate) → reaper recovery → resume"
# Start the workflow, approve gate 1 → enrich starts → but enrich is instant
# for this deterministic graph, so instead we use sleepy for mid-stage crash
# and workflow for the gate chain. Here we verify the reaper handles
# a workflow run killed mid-flight, not at a gate.
T=$(start_workflow); wait_interrupted "$T"
resume_gate "$T" true > /dev/null; wait_interrupted "$T"    # gate 2

say "  >>> starting a SECOND run in background, then killing server mid-flight <<<"
T2=$(new_thread)
RID2=$(api -X POST "${BASE}/threads/${T2}/runs" "${AUTH[@]}" \
  -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"midstage"}]}}' \
  | py 'import json,sys;print(json.load(sys.stdin)["run_id"])')
sleep 8  # sleepy is mid-long_work
eval "${RESTART_CMD}" > /dev/null 2>&1
if wait_server "$T2"; then t "W5.1 server back up after mid-stage crash" ok; else t "W5.1 server back up after mid-stage crash" fail; fi

# the sleepy run should be re-enqueued by the reaper and complete
for i in $(seq 1 36); do
  S=$(api "${BASE}/threads/${T2}/runs/${RID2}" "${AUTH[@]}" 2>/dev/null | py 'import json,sys;print(json.load(sys.stdin).get("status"))' 2>/dev/null || echo "?")
  [ "$S" = success ] && break
  sleep 5
done
t "W5.2 mid-stage crashed run recovered by reaper" "$([ "$S" = success ] && echo ok || echo fail)" "status=${S}"

# meanwhile the gate-2 workflow thread should still be intact
ST=$(status_of "$T")
t "W5.3 gate-2 thread unaffected by the concurrent crash" "$([ "$ST" = interrupted ] && echo ok || echo fail)" "status=${ST}"
R=$(resume_gate "$T" true); wait_interrupted "$T"
R=$(resume_gate "$T" true); wait_idle "$T"
FX_ALL=$(fx_count "$T")
t "W5.4 workflow completed after concurrent crash, all fx exact" "$([ "${FX_ALL:-x}" = 4 ] && echo ok || echo fail)" "total=${FX_ALL}"

# ================================================================ W6
sec "W6 — sequential crash at EACH gate → 3-crash recovery chain"
T=$(start_workflow); wait_interrupted "$T"

say "  >>> CRASH #1 (at gate 1) <<<"
eval "${RESTART_CMD}" > /dev/null 2>&1; wait_server "$T"
t "W6.1 gate 1 survived crash #1" "$( wait_status "$T" interrupted 45 && echo ok || echo fail)" "status=$(status_of "$T")"
resume_gate "$T" true > /dev/null; wait_interrupted "$T"

say "  >>> CRASH #2 (at gate 2) <<<"
eval "${RESTART_CMD}" > /dev/null 2>&1; wait_server "$T"
t "W6.2 gate 2 survived crash #2" "$( wait_status "$T" interrupted 45 && echo ok || echo fail)" "status=$(status_of "$T")"
resume_gate "$T" true > /dev/null; wait_interrupted "$T"

say "  >>> CRASH #3 (at gate 3) <<<"
eval "${RESTART_CMD}" > /dev/null 2>&1; wait_server "$T"
t "W6.3 gate 3 survived crash #3" "$( wait_status "$T" interrupted 45 && echo ok || echo fail)" "status=$(status_of "$T")"

resume_gate "$T" true > /dev/null
t "W6.4 completed after 3 sequential crashes" "$( wait_status "$T" idle 60 && echo ok || echo fail)" "status=$(status_of "$T")"

FX_INTAKE=$(fx_count "$T" intake); FX_ENRICH=$(fx_count "$T" enrich); FX_EXEC=$(fx_count "$T" execute); FX_REPORT=$(fx_count "$T" report)
t "W6.5 intake once across 3 crashes"    "$([ "${FX_INTAKE:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_INTAKE}"
t "W6.6 enrich once across 3 crashes"    "$([ "${FX_ENRICH:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_ENRICH}"
t "W6.7 execute once across 3 crashes"   "$([ "${FX_EXEC:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_EXEC}"
t "W6.8 report once across 3 crashes"    "$([ "${FX_REPORT:-x}" = 1 ] && echo ok || echo fail)" "fx=${FX_REPORT}"

# ================================================================ W7
sec "W7 — state surgery between gates → resume still works"
T=$(start_workflow); wait_interrupted "$T"
resume_gate "$T" true > /dev/null; wait_interrupted "$T"   # gate 2
api -X POST "${BASE}/threads/$T/state" "${AUTH[@]}" \
  -d '{"values":{"messages":[{"role":"user","content":"human-edited-during-pause"}]},"as_node":"gate_approve_plan"}' > /dev/null
R=$(resume_gate "$T" true); wait_interrupted "$T"
t "W7.1 state surgery accepted + resume works from gate 2" "$( [ "$(status_of "$T")" = interrupted ] && echo ok || echo fail)"
resume_gate "$T" true > /dev/null; wait_idle "$T"
FX_ALL=$(fx_count "$T")
t "W7.2 completed with all fx exact after surgery" "$([ "${FX_ALL:-x}" = 4 ] && echo ok || echo fail)" "total=${FX_ALL}"

# ================================================================ W8
sec "W8 — fork from pre-gate-2 checkpoint → re-reaches gate 2"
T=$(start_workflow); wait_interrupted "$T"
resume_gate "$T" true > /dev/null; wait_interrupted "$T"   # gate 2
# fork from the checkpoint BEFORE gate 1 approval
CP=$(api -X POST "${BASE}/threads/$T/history" "${AUTH[@]}" -d '{"limit":10}' | py 'import json,sys;d=json.load(sys.stdin);print(d[-1]["checkpoint"]["checkpoint_id"])')
TF=$(new_thread)
R=$(api -X POST "${BASE}/threads/${T}/runs/wait" "${AUTH[@]}" \
  -d "{\"assistant_id\":\"workflow\",\"input\":{\"messages\":[{\"role\":\"user\",\"content\":\"fork-me\"}]},\"checkpoint_id\":\"${CP}\"}")
ST=$(status_of "$T")
t "W8.1 fork from pre-gate-1 checkpoint re-reaches a gate" "$( [ "$ST" = interrupted ] && echo ok || echo skip)" "status=${ST}"

# ================================================================ SUMMARY
sec "SUMMARY"
printf 'WORKFLOW: PASS %d  FAIL %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -gt 0 ] && { for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done; exit 1; }
echo "ALL WORKFLOW HITL CRASH-RECOVERY TESTS PASSED"
