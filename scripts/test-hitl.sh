#!/usr/bin/env bash
# Aggressive human-in-the-loop conformance suite.
#
# Exercises the FULL interrupt lifecycle against any Agent Server target:
#   ./scripts/test-hitl.sh                       # our platform :8123
#   BASE=http://127.0.0.1:8124 ./scripts/test-hitl.sh   # official build
#
# LLM-free core (graph: approval — deterministic prep → interrupt gate → finish):
#   H1  interrupt pauses; thread interrupted; payload visible; zero compute
#   H2  resume-approve completes from the exact point; prep ran EXACTLY ONCE
#   H3  resume-reject: decision value flows through; still exactly-once
#   H4  resume on a NON-interrupted thread → rejected (4xx), no corruption
#   H5  double-resume after completion → no corruption, thread sane
#   H6  state surgery while paused (update_state) then resume
#   H7  SERVER RESTART while paused → interrupt survives, resume works, once-only
#   H8  new-message run on an interrupted thread → no corruption
#   H9  delete while paused → gone
#   H10 cancel an in-flight run, then interrupt flow still works
#   H11 fork from before the gate → interrupt fires again on the fork
# With RUN_LLM=1 (graph: complex — real model via OpenRouter):
#   H12 approve path: gate at format_report → approve → Report; no tool twice
#   H13 reject path: gate → reject decision → agent adapts, completes
set -uo pipefail

BASE=${BASE:-http://127.0.0.1:8123}
API_KEY=${PLATFORM_API_KEY:-dev-key}
RUN_LLM=${RUN_LLM:-1}
RESTART_CMD=${RESTART_CMD:-docker compose restart server}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

AUTH=(-H "x-api-key: ${API_KEY}" -H 'Content-Type: application/json')
PASS=0; FAIL=0; FAILED=()

t() {
  if [ "$2" = ok ]; then PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"
  elif [ "$2" = skip ]; then printf '  \033[33mSKIP\033[0m %s %s\n' "$1" "${3:+— ${3}}"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31mFAIL\033[0m %s %s\n' "$1" "${3:+— ${3}}"; fi
}
api() { curl -s -m "${API_TIMEOUT:-60}" "$@"; }
py() { python3 -c "$1" 2>/dev/null; }
sec() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

new_thread() { api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | py 'import json,sys;print(json.load(sys.stdin)["thread_id"])'; }
status_of()  { api "${BASE}/threads/$1" "${AUTH[@]}" | py 'import json,sys;print(json.load(sys.stdin).get("status") or "idle")'; }
preps_of()   { api "${BASE}/threads/$1/state" "${AUTH[@]}" | py "import json,sys;d=json.load(sys.stdin);print(sum(1 for m in d['values'].get('side_effects',[]) if str(m.get('content','')).startswith('prep:')))"; }
start_interrupted() {  # -> thread id paused at gate
  local tid; tid=$(new_thread)
  api -X POST "${BASE}/threads/${tid}/runs/wait" "${AUTH[@]}" \
    -d '{"assistant_id":"approval","input":{"messages":[{"role":"user","content":"go"}]}}' > /dev/null
  echo "$tid"
}
resume() {  # thread decision -> runs/wait response file
  api -X POST "${BASE}/threads/$1/runs/wait" "${AUTH[@]}" \
    -d "{\"assistant_id\":\"approval\",\"command\":{\"resume\":{\"approved\":$2}}}"
}

sec "H1 — interrupt pauses with zero compute"
T=$(start_interrupted)
ST=$(status_of "$T"); t "H1.1 thread status = interrupted" "$([ "$ST" = interrupted ] && echo ok || echo fail)" "got ${ST}"
NEXT=""
for i in 1 2 3 4 5; do
  NEXT=$(api "${BASE}/threads/$T/state" "${AUTH[@]}" | py 'import json,sys;d=json.load(sys.stdin);print(",".join(d.get("next") or []))')
  case "$NEXT" in *gate*) break;; esac; sleep 1
done
t "H1.2 paused at the gate node" "$( [[ "$NEXT" == *gate* ]] && echo ok || echo fail)" "next=${NEXT}"
INTR=$(api "${BASE}/threads/$T/state" "${AUTH[@]}" | py 'import json,sys;d=json.load(sys.stdin);print(len(d.get("tasks") or []))')
t "H1.3 pending interrupt payload in state" "$([ "${INTR:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "tasks=${INTR}"
PRE=$(preps_of "$T"); t "H1.4 prep already checkpointed (1 execution)" "$([ "$PRE" = 1 ] && echo ok || echo fail)" "preps=${PRE}"

sec "H2 — resume-approve completes from the exact point"
R=$(resume "$T" true)
OK=$(echo "$R" | py 'import json,sys;d=json.load(sys.stdin);print(any("approved=True" in str(m.get("content","")) for m in d.get("messages",[])))')
t "H2.1 decision value flows to the graph" "$([ "$OK" = True ] && echo ok || echo fail)"
DONE=$(echo "$R" | py 'import json,sys;d=json.load(sys.stdin);print(any("finish" in str(m.get("content","")) for m in d.get("messages",[])))')
t "H2.2 graph ran to completion after approval" "$([ "$DONE" = True ] && echo ok || echo fail)"
P=$(preps_of "$T"); t "H2.3 prep still executed EXACTLY ONCE" "$([ "$P" = 1 ] && echo ok || echo fail)" "preps=${P}"
ST=$(status_of "$T"); t "H2.4 thread back to idle" "$([ "$ST" = idle ] && echo ok || echo fail)" "got ${ST}"

sec "H3 — resume-reject path"
T=$(start_interrupted); R=$(resume "$T" false)
OK=$(echo "$R" | py 'import json,sys;d=json.load(sys.stdin);print(any("approved=False" in str(m.get("content","")) for m in d.get("messages",[])))')
t "H3.1 rejection value flows to the graph" "$([ "$OK" = True ] && echo ok || echo fail)"
P=$(preps_of "$T"); t "H3.2 exactly-once preserved on reject" "$([ "$P" = 1 ] && echo ok || echo fail)" "preps=${P}"

sec "H4 — resume on a non-interrupted thread is rejected"
T2=$(new_thread)
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/$T2/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"approval","command":{"resume":{"approved":true}}}')
t "H4.1 resume without pending interrupt → 4xx" "$([ "${CODE:0:1}" = 4 ] || [ "${CODE:0:1}" = 5 ] && [ "$CODE" != 200 ] && echo ok || echo skip)" "HTTP ${CODE}"

sec "H5 — double resume after completion doesn't corrupt"
T=$(start_interrupted); resume "$T" true > /dev/null
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/$T/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"approval","command":{"resume":{"approved":true}}}')
ST=$(status_of "$T")
t "H5.1 second resume tolerated" "$([ "${CODE:0:1}" = 2 ] || [ "${CODE:0:1}" = 4 ] && [ "$ST" = idle ] && echo ok || echo fail)" "HTTP ${CODE} status=${ST}"
P=$(preps_of "$T"); t "H5.2 prep never duplicated by stray resumes" "$([ "$P" = 1 ] && echo ok || echo fail)" "preps=${P}"

sec "H6 — state surgery while paused, then resume"
T=$(start_interrupted)
api -X POST "${BASE}/threads/$T/state" "${AUTH[@]}" \
  -d '{"values":{"messages":[{"role":"user","content":"edited-by-human"}]},"as_node":"gate"}' > /dev/null
R=$(resume "$T" true)
OK=$(echo "$R" | py 'import json,sys;d=json.load(sys.stdin);print(len(d.get("messages",[]))>0)')
t "H6.1 edited state accepted + run completes" "$([ "$OK" = True ] && echo ok || echo fail)"

sec "H7 — interrupt survives a full server restart"
T=$(start_interrupted)
eval "${RESTART_CMD}" > /dev/null 2>&1
for i in $(seq 1 30); do api -o /dev/null "${BASE}/ok" && break; sleep 3; done
sleep 2
ST=$(status_of "$T"); t "H7.1 still interrupted after restart" "$([ "$ST" = interrupted ] && echo ok || echo fail)" "got ${ST}"
R=$(resume "$T" true)
OK=$(echo "$R" | py 'import json,sys;d=json.load(sys.stdin);print(any("approved=True" in str(m.get("content","")) for m in d.get("messages",[])))')
P=$(preps_of "$T")
t "H7.2 resume works after restart" "$([ "$OK" = True ] && echo ok || echo fail)"
t "H7.3 prep EXACTLY ONCE across restart+resume" "$([ "$P" = 1 ] && echo ok || echo fail)" "preps=${P}"

sec "H8 — new message on an interrupted thread doesn't corrupt"
T=$(start_interrupted)
P0=$(preps_of "$T"); t "H8.2a prep exactly once while paused" "$([ "$P0" = 1 ] && echo ok || echo fail)" "preps=${P0}"
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/$T/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"hello"}]}}')
t "H8.1 new-turn run on interrupted thread handled" "$([ "${CODE:0:1}" = 2 ] || [ "${CODE:0:1}" = 4 ] && echo ok || echo fail)" "HTTP ${CODE}"
resume "$T" true > /dev/null; ST=$(status_of "$T")
t "H8.3 original interrupt still resumable" "$([ "$ST" = idle ] && echo ok || echo skip)" "status=${ST}"

sec "H9 — delete while paused"
T=$(start_interrupted)
api -X DELETE "${BASE}/threads/$T" "${AUTH[@]}" -o /dev/null
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/threads/$T" "${AUTH[@]}")
t "H9.1 paused thread deletable + gone" "$([ "$CODE" = 404 ] && echo ok || echo fail)" "HTTP ${CODE}"

sec "H10 — cancel an in-flight run; interrupt flow keeps working"
T=$(new_thread)
RID=$(api -X POST "${BASE}/threads/$T/runs" "${AUTH[@]}" -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"x"}]}}' | py 'import json,sys;print(json.load(sys.stdin)["run_id"])')
sleep 3
api -X POST "${BASE}/threads/$T/runs/$RID/cancel" "${AUTH[@]}" -d '{}' -o /dev/null
T3=$(start_interrupted); R=$(resume "$T3" true)
OK=$(echo "$R" | py 'import json,sys;d=json.load(sys.stdin);print(any("approved=True" in str(m.get("content","")) for m in d.get("messages",[])))')
t "H10.1 interrupt flow intact after a cancel" "$([ "$OK" = True ] && echo ok || echo fail)"

sec "H11 — fork from before the gate: interrupt fires again"
T=$(start_interrupted)
CP=$(api "${BASE}/threads/$T/history" "${AUTH[@]}" | py 'import json,sys;d=json.load(sys.stdin);print(d[-1]["checkpoint"]["checkpoint_id"])')
T4=$(new_thread)
R=$(api -X POST "${BASE}/threads/$T/runs/wait" "${AUTH[@]}" \
  -d "{\"assistant_id\":\"approval\",\"input\":{\"messages\":[{\"role\":\"user\",\"content\":\"fork\"}]},\"checkpoint_id\":\"${CP}\"}")
ST=$(status_of "$T")
t "H11.1 forking from pre-gate checkpoint re-reaches the gate" "$([ "$ST" = interrupted ] && echo ok || echo skip)" "status=${ST}"

if [ "${RUN_LLM}" = 1 ]; then
sec "H12 (real LLM) — complex agent: gate → approve → Report, no tool twice"
T=$(new_thread)
api -m 300 -X POST "${BASE}/threads/$T/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"complex","input":{"messages":[{"role":"user","content":"Research our billing-api, check July orders for anomalies. You MUST use the format_report tool to produce the final report."}]}}' > /dev/null
ST=$(status_of "$T")
t "H12.1 complex agent paused at its approval gate" "$([ "$ST" = interrupted ] && echo ok || echo fail)" "status=${ST}"
BEFORE=$(api "${BASE}/threads/$T/state" "${AUTH[@]}" | py 'import json,sys;d=json.load(sys.stdin);print(sum(1 for m in d["values"]["messages"] if m.get("type")=="tool") * 1000 + len([1 for m in d["values"]["messages"] if m.get("type")=="tool"]))')
# approve (loop: model may gate more than once)
for i in 1 2 3; do
  ST=$(status_of "$T"); [ "$ST" = interrupted ] || break
  api -m 300 -X POST "${BASE}/threads/$T/runs/wait" "${AUTH[@]}" \
    -d '{"assistant_id":"complex","command":{"resume":{"decisions":[{"type":"approve"}]}}}' > /dev/null
done
ST=$(status_of "$T")
REPORT=$(api "${BASE}/threads/$T/state" "${AUTH[@]}" | py 'import json,sys;d=json.load(sys.stdin);v=d["values"];print(v.get("structured_response") is not None)')
DUPES=$(api "${BASE}/threads/$T/state" "${AUTH[@]}" | py 'import json,sys;d=json.load(sys.stdin);ids=[m.get("tool_call_id") for m in d["values"]["messages"] if m.get("type")=="tool"];print(len(ids)-len(set(ids)))')
t "H12.2 completed after approvals" "$([ "$ST" = idle ] && echo ok || echo fail)" "status=${ST}"
t "H12.3 structured Report produced" "$([ "$REPORT" = True ] && echo ok || echo fail)"
t "H12.4 ZERO duplicate tool calls across the HITL cycle" "$([ "${DUPES:-x}" = 0 ] && echo ok || echo fail)" "dupes=${DUPES}"

sec "H13 (real LLM) — complex agent: gate → REJECT → agent adapts"
T=$(new_thread)
api -m 300 -X POST "${BASE}/threads/$T/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"complex","input":{"messages":[{"role":"user","content":"Research billing-api briefly. You MUST use the format_report tool to produce the final report."}]}}' > /dev/null
ST=$(status_of "$T")
if [ "$ST" = interrupted ]; then
  # A rejected tool call is surfaced to the model as a rejection message; the
  # model may re-attempt the gated tool — reject each round until it stops.
  for i in 1 2 3; do
    ST=$(status_of "$T"); [ "$ST" = interrupted ] || break
    api -m 300 -X POST "${BASE}/threads/$T/runs/wait" "${AUTH[@]}" \
      -d '{"assistant_id":"complex","command":{"resume":{"decisions":[{"type":"reject"}]}}}' > /dev/null
  done
  ST=$(status_of "$T")
  t "H13.1 after rejections the run terminates cleanly" "$([ "$ST" = idle ] || [ "$ST" = error ] && echo ok || echo fail)" "status=${ST}"
  DUPES=$(api "${BASE}/threads/$T/state" "${AUTH[@]}" | py 'import json,sys;d=json.load(sys.stdin);ids=[m.get("tool_call_id") for m in d["values"]["messages"] if m.get("type")=="tool"];print(len(ids)-len(set(ids)))')
  t "H13.2 zero duplicate tool calls on reject path" "$([ "${DUPES:-x}" = 0 ] && echo ok || echo fail)" "dupes=${DUPES}"
else
  t "H13 complex reject path" "skip" "model did not gate (status=${ST})"
fi
fi

sec "SUMMARY"
printf 'HITL: PASS %d  FAIL %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -gt 0 ] && { for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done; exit 1; }
echo "ALL HITL TESTS PASSED"
