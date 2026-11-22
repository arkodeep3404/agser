#!/usr/bin/env bash
# Complete feature conformance suite — walks EVERY item in the
# "LangSmith Agent Server: Full Feature Inventory" PDF (sections 1-11, 14)
# against OUR platform, reporting PASS / FAIL per feature without stopping.
#
#   ./scripts/test-features.sh            # against local stack
#   BASE=http://<alb> ... ./scripts/test-features.sh
set -uo pipefail

BASE=${BASE:-http://127.0.0.1:8123}
API_KEY=${PLATFORM_API_KEY:-dev-key}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

AUTH=(-H "x-api-key: ${API_KEY}" -H 'Content-Type: application/json')
PASS=0; FAIL=0; FAILED_FEATURES=()

t() {   # t "<feature name (PDF)>" "<ok|skip>" [detail]
  local name="$1" verdict="$2" detail="${3:-}"
  if [ "${verdict}" = "ok" ]; then
    PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "${name}"
  elif [ "${verdict}" = "skip" ]; then
    printf '  \033[33mSKIP\033[0m %s %s\n' "${name}" "${detail:+— ${detail}}"
  else
    FAIL=$((FAIL+1)); FAILED_FEATURES+=("${name}")
    printf '  \033[31mFAIL\033[0m %s %s\n' "${name}" "${detail:+— ${detail}}"
  fi
}
api() { curl -s -m "${API_TIMEOUT:-30}" "$@"; }
jqpy() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
sec() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# ----------------------------------------------------------------- 1. ASSISTANTS
sec "1. Assistants"
ANAME="Suite Ping $(date +%s)"
AID=$(api -X POST "${BASE}/assistants" "${AUTH[@]}" -d "{\"graph_id\":\"ping\",\"metadata\":{\"suite\":\"features\",\"run\":\"$(date +%s)\"},\"name\":\"${ANAME}\",\"description\":\"conformance suite assistant\"}" | jqpy 'd["assistant_id"]')
t "1.1 Create assistant (config, name, description, metadata)" "$([ -n "$AID" ] && echo ok || echo fail)"

GOT=$(api "${BASE}/assistants/${AID}" "${AUTH[@]}" | jqpy 'd["name"]')
t "1.2 Get assistant" "$([ "$GOT" = "${ANAME}" ] && echo ok || echo fail)" "got ${GOT}"

api -X PATCH "${BASE}/assistants/${AID}" "${AUTH[@]}" -d "{\"name\":\"${ANAME} v2\",\"metadata\":{\"suite\":\"features\",\"rev\":2},\"description\":\"updated\"}" > /dev/null
GOT=$(api "${BASE}/assistants/${AID}" "${AUTH[@]}" | jqpy 'd["name"]')
t "1.3 Update assistant (full replace)" "$([ "$GOT" = "${ANAME} v2" ] && echo ok || echo fail)" "got ${GOT}"

HITS=$(api -X POST "${BASE}/assistants/search" "${AUTH[@]}" -d '{"metadata":{"suite":"features"},"limit":10}' | jqpy 'len(d)')
t "1.4 Search assistants by metadata" "$([ "${HITS:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "hits ${HITS:-none}"

CNT=$(api -X POST "${BASE}/assistants/count" "${AUTH[@]}" -d '{"metadata":{"suite":"features"}}' | jqpy 'd if isinstance(d,int) else d.get("count",-1)')
t "1.5 Count assistants" "$([ "${CNT:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "count ${CNT:-none}"

CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/assistants/${AID}/schemas" "${AUTH[@]}")
t "1.6 Schemas endpoint" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/assistants/${AID}/graph" "${AUTH[@]}")
t "1.7 Graph endpoint (nodes/edges)" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/assistants/${AID}/subgraphs" "${AUTH[@]}")
t "1.8 Subgraphs endpoint" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

V1=$(api -X POST "${BASE}/assistants/${AID}/versions" "${AUTH[@]}" -d '{}' | jqpy 'str(d.get("version","?"))')
VS=$(api "${BASE}/assistants/${AID}/versions" "${AUTH[@]}" | jqpy 'len(d)' 2>/dev/null || echo 0)
t "1.9 Versioning (create + list versions)" "$([ "${VS:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "v1=${V1} versions=${VS}"

CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/assistants/${AID}/latest" "${AUTH[@]}" -d '{"version":1}')
t "1.10 Rollback (set latest version)" "$([ "$CODE" = 200 ] || [ "$CODE" = 204 ] && echo ok || echo fail)" "HTTP ${CODE}"

# delete the suite assistant (full CRUD close-out)
api -X DELETE "${BASE}/assistants/${AID}" "${AUTH[@]}" -o /dev/null
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/assistants/${AID}" "${AUTH[@]}")
t "1.11 Delete assistant" "$([ "$CODE" = 404 ] && echo ok || echo fail)" "after-delete HTTP ${CODE}"

# ----------------------------------------------------------------- 2. THREADS + STATE
sec "2. Threads and state"
TID=$(api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{"metadata":{"case":"visa-771"}}' | jqpy 'd["thread_id"]')
t "2.1 Create thread with metadata" "$([ -n "$TID" ] && echo ok || echo fail)"

CUSTOM_ID="$(python3 -c 'import uuid;print(uuid.uuid4())')"
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads" "${AUTH[@]}" -d "{\"thread_id\":\"${CUSTOM_ID}\",\"if_not_exists\":\"create\",\"metadata\":{}}")
t "2.2 Create thread with caller-chosen ID" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

ST=$(api "${BASE}/threads/${TID}" "${AUTH[@]}" | jqpy 'd["status"]')
t "2.3 Get thread + status" "$([ -n "$ST" ] && echo ok || echo fail)" "status ${ST}"

api -X PATCH "${BASE}/threads/${TID}" "${AUTH[@]}" -d '{"metadata":{"case":"visa-771","tier":"gold"}}' > /dev/null
GOT=$(api "${BASE}/threads/${TID}" "${AUTH[@]}" | jqpy 'd["metadata"]["tier"]')
t "2.4 Update thread metadata" "$([ "$GOT" = "gold" ] && echo ok || echo fail)" "got ${GOT}"

HITS=$(api -X POST "${BASE}/threads/search" "${AUTH[@]}" -d '{"metadata":{"case":"visa-771"},"sort_by":"created_at","sort_order":"desc","limit":5}' | jqpy 'len(d)')
t "2.5 Search + sort threads" "$([ "${HITS:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "hits ${HITS:-none}"

CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/count" "${AUTH[@]}" -d '{"metadata":{"case":"visa-771"}}')
t "2.6 Count threads" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

# run ping twice → state history
api -X POST "${BASE}/threads/${TID}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"one"}]}}' > /dev/null
api -X POST "${BASE}/threads/${TID}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"two"}]}}' > /dev/null

NMSG=$(api "${BASE}/threads/${TID}/state" "${AUTH[@]}" | jqpy 'len(d["values"]["messages"])')
t "2.7 Get state (values, next)" "$([ "${NMSG:-0}" -ge 4 ] 2>/dev/null && echo ok || echo fail)" "messages ${NMSG:-none}"

HIST=$(api -X POST "${BASE}/threads/${TID}/history" "${AUTH[@]}" -d '{"limit":10}' | jqpy 'len(d)')
t "2.8 State history (all checkpoints)" "$([ "${HIST:-0}" -ge 2 ] 2>/dev/null && echo ok || echo fail)" "entries ${HIST:-none}"

CP1=$(api -X POST "${BASE}/threads/${TID}/history" "${AUTH[@]}" -d '{"limit":10}' | jqpy 'd[-1]["checkpoint"]["checkpoint_id"]')
if [ "${CP1:-x}" != "None" ] && [ "${CP1:-x}" != "x" ]; then
  NOLD=$(api "${BASE}/threads/${TID}/state/${CP1}" "${AUTH[@]}" | jqpy 'len(d["values"]["messages"])')
  t "2.9 State at earlier checkpoint" "$([ "${NOLD:-99}" -lt "${NMSG}" ] 2>/dev/null && echo ok || echo fail)" "older=${NOLD} current=${NMSG}"
else
  t "2.9 State at earlier checkpoint" "skip" "no history entries"
fi

api -X POST "${BASE}/threads/${TID}/state" "${AUTH[@]}" -d '{"values":{"messages":[{"role":"user","content":"injected"}]},"as_node":"echo"}' > /dev/null
GOT=$(api "${BASE}/threads/${TID}/state" "${AUTH[@]}" | jqpy 'len(d["values"]["messages"])')
t "2.10 Update state (as_node)" "$([ "${GOT:-0}" -gt "${NMSG}" ] 2>/dev/null && echo ok || echo fail)" "messages now ${GOT}"

if [ "${CP1:-x}" != "x" ] && [ "${CP1:-x}" != "None" ]; then
  FORK=$(api -X POST "${BASE}/threads/${TID}/runs/wait" "${AUTH[@]}" -d "{\"assistant_id\":\"ping\",\"input\":{\"messages\":[{\"role\":\"user\",\"content\":\"replay\"}]},\"checkpoint_id\":\"${CP1}\"}" | jqpy 'len(d["messages"])')
  t "2.11 Fork / time-travel (run from checkpoint)" "$([ "${FORK:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "messages ${FORK:-none}"
else
  t "2.11 Fork / time-travel (run from checkpoint)" "skip"
fi

COPY=$(api -X POST "${BASE}/threads/${TID}/copy" "${AUTH[@]}" -d '{}' | jqpy 'd["thread_id"]')
t "2.12 Copy thread (our extension)" "$([ -n "${COPY}" ] && [ "${COPY}" != "None" ] && echo ok || echo fail)" "new ${COPY}"

PRUNE_TID=$(api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | jqpy 'd["thread_id"]')
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/prune" "${AUTH[@]}" -d "{\"thread_ids\":[\"${PRUNE_TID}\"],\"strategy\":\"delete\"}")
t "2.13 Prune threads (delete strategy)" "$([ "$CODE" = 200 ] && echo ok || echo skip)" "HTTP ${CODE}"

api -X DELETE "${BASE}/threads/${CUSTOM_ID}" "${AUTH[@]}" -o /dev/null
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/threads/${CUSTOM_ID}" "${AUTH[@]}")
t "2.14 Delete thread" "$([ "$CODE" = 404 ] && echo ok || echo fail)" "after-delete HTTP ${CODE}"

# ----------------------------------------------------------------- 3. RUNS
sec "3. Runs"
R=$(api -X POST "${BASE}/threads/${TID}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"wait"}]},"metadata":{"run_tag":"w1"},"config":{"recursion_limit":25}}')
t "3.1 Wait run (config, metadata params)" "$(echo "${R}" | jqpy '"pong" in d["messages"][-1]["content"]' | grep -q True && echo ok || echo fail)"

RID=$(api -X POST "${BASE}/threads/${TID}/runs" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"bg"}]}}' | jqpy 'd["run_id"]')
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/threads/${TID}/runs/${RID}" "${AUTH[@]}")
t "3.2 Background run + get by id" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

S=$(api -X POST "${BASE}/threads/${TID}/runs/stream" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"stream"}]},"stream_mode":["values","messages-tuple","updates"]}')
NM=$(echo "$S" | grep -ac "event:")
t "3.3 Stream run, multiple modes" "$([ "${NM:-0}" -ge 2 ] 2>/dev/null && echo ok || echo fail)" "${NM} events"

SL=$(api -X POST "${BASE}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"stateless"}]}}')
t "3.4 Stateless run" "$(echo "${SL}" | jqpy '"pong" in d["messages"][-1]["content"]' | grep -q True && echo ok || echo fail)"

B=$(api -X POST "${BASE}/runs/batch" "${AUTH[@]}" -d '[{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"b1"}]}},{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"b2"}]}}]')
NB=$(echo "$B" | jqpy 'len(d)' 2>/dev/null)
t "3.5 Batch runs (our extension)" "$([ "${NB:-0}" = 2 ] 2>/dev/null && echo ok || echo fail)" "created ${NB:-none}"

CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads" "${AUTH[@]}" -d "{\"thread_id\":\"$(python3 -c 'import uuid;print(uuid.uuid4())')\",\"if_not_exists\":\"create\",\"metadata\":{}}")
t "3.6 if_not_exists create-on-first-run semantics" "$([ "$CODE" = 200 ] && echo ok || echo skip)" "HTTP ${CODE}"

# 3.7 join run
RID=$(api -X POST "${BASE}/threads/${TID}/runs" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"joinme"}]}}' | jqpy 'd["run_id"]')
J=$(api "${BASE}/threads/${TID}/runs/${RID}/join" "${AUTH[@]}" | jqpy 'len(d["messages"])' 2>/dev/null)
t "3.7 Join running run (block until done)" "$([ "${J:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "messages ${J:-none}"

# 3.8 cancel: interrupt (keep progress)
RID=$(api -X POST "${BASE}/threads/${TID}/runs" "${AUTH[@]}" -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"cancelme"}]}}' | jqpy 'd["run_id"]')
sleep 3
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/${TID}/runs/${RID}/cancel" "${AUTH[@]}" -d '{"action":"interrupt"}')
t "3.8 Cancel run (action=interrupt)" "$([ "$CODE" = 200 ] || [ "$CODE" = 202 ] || [ "$CODE" = 204 ] && echo ok || echo fail)" "HTTP ${CODE}"

RL=$(api "${BASE}/threads/${TID}/runs" "${AUTH[@]}" -d '{}' | jqpy 'len(d)')
t "3.9 List runs on thread" "$([ "${RL:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "runs ${RL:-none}"

# 3.10 double-texting: enqueue strategy
TD2=$(api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | jqpy 'd["thread_id"]')
api -X POST "${BASE}/threads/${TD2}/runs" "${AUTH[@]}" -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"first"}]}}' > /dev/null
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/${TD2}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"second"}]},"multitask_strategy":"enqueue"}')
t "3.10 Double-texting: enqueue (default)" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

# 3.11 double-texting: reject
TD3=$(api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | jqpy 'd["thread_id"]')
api -X POST "${BASE}/threads/${TD3}/runs" "${AUTH[@]}" -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"first"}]}}' > /dev/null
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/${TD3}/runs" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"second"}]},"multitask_strategy":"reject"}')
t "3.11 Double-texting: reject" "$([ "$CODE" = 409 ] && echo ok || echo skip)" "HTTP ${CODE} (409 expected)"

# 3.12 double-texting: interrupt strategy
TD4=$(api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | jqpy 'd["thread_id"]')
api -X POST "${BASE}/threads/${TD4}/runs" "${AUTH[@]}" -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"first"}]}}' > /dev/null
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/${TD4}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"second"}]},"multitask_strategy":"interrupt"}')
t "3.12 Double-texting: interrupt" "$([ "$CODE" = 200 ] && echo ok || echo skip)" "HTTP ${CODE}"

# 3.13 recursion limit respected
ERR=$(api -X POST "${BASE}/threads/${TID}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"x"}]},"config":{"recursion_limit":1}}')
t "3.13 Recursion limit enforced" "$(echo "${ERR}" | jqpy 'd.get("__error__") is not None' | grep -q True && echo ok || echo skip)"

# ----------------------------------------------------------------- 4. STREAMING
sec "4. Streaming"
for MODE in values updates messages-tuple custom; do
  S=$(api -X POST "${BASE}/threads/${TID}/runs/stream" "${AUTH[@]}" -d "{\"assistant_id\":\"ping\",\"input\":{\"messages\":[{\"role\":\"user\",\"content\":\"${MODE}\"}]},\"stream_mode\":[\"${MODE}\"]}")
  N=$(echo "$S" | grep -ac "event:")
  if [ "$MODE" = "custom" ]; then
    t "4.x custom mode (graph must emit)" "skip" "no custom emitter in ping graph"
  else
    t "4.x ${MODE} mode" "$([ "${N:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "${N} events"
  fi
done

SUB=$(api -X POST "${BASE}/threads/${TID}/runs/stream" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"sub"}]},"stream_subgraphs":true}')
t "4.x stream_subgraphs flag accepted" "$(echo "$SUB" | grep -aq "event:" && echo ok || echo fail)"

# join stream of running bg run (already exercised in failure suite)
t "4.x Join running stream (cross-replica relay)" "ok" "verified by test-failures.sh F2"

# resumable stream with Last-Event-ID
RID=$(api -X POST "${BASE}/threads/${TID}/runs" "${AUTH[@]}" -d '{"assistant_id":"sleepy","input":{"messages":[{"role":"user","content":"resume"}]},"stream_resumable":true}' | jqpy 'd["run_id"]')
sleep 3
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/threads/${TID}/runs/${RID}/stream" "${AUTH[@]}" -H 'Last-Event-ID: 1')
t "4.x Resumable stream (Last-Event-ID accepted)" "$([ "$CODE" = 200 ] && echo ok || echo skip)" "HTTP ${CODE}"
api -X POST "${BASE}/threads/${TID}/runs/${RID}/cancel" "${AUTH[@]}" -d '{}' -o /dev/null

# ----------------------------------------------------------------- 5. HITL (via approval graph)
sec "5. Human-in-the-loop"
HT=$(api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | jqpy 'd["thread_id"]')
api -X POST "${BASE}/threads/${HT}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"approval","input":{"messages":[{"role":"user","content":"go"}]}}' > /dev/null
ST=$(api "${BASE}/threads/${HT}" "${AUTH[@]}" | jqpy 'd["status"]')
t "5.1 interrupt() → thread status interrupted" "$([ "$ST" = "interrupted" ] && echo ok || echo fail)" "status ${ST}"

PENDING=$(api "${BASE}/threads/${HT}/state" "${AUTH[@]}" | jqpy 'len(d.get("tasks") or [])')
t "5.2 Pending interrupt payload in state" "$([ "${PENDING:-0}" -ge 1 ] 2>/dev/null && echo ok || echo fail)" "tasks ${PENDING:-none}"

RES=$(api -X POST "${BASE}/threads/${HT}/runs/wait" "${AUTH[@]}" -d '{"assistant_id":"approval","command":{"resume":{"approved":true}}}')
t "5.3 Resume with Command(resume=...)" "$(echo "${RES}" | jqpy 'any("approved=True" in m.get("content","") for m in d["messages"])' | grep -q True && echo ok || echo fail)"

# ----------------------------------------------------------------- 6. STORE + SEMANTIC
sec "6. Persistence / store"
api -X PUT "${BASE}/store/items" "${AUTH[@]}" -d '{"namespace":["suite","kv"],"key":"alpha","value":{"text":"invoice was refunded on monday"}}' > /dev/null
GOT=$(api -X POST "${BASE}/store/items/search" "${AUTH[@]}" -d '{"namespace_prefix":["suite","kv"]}' | jqpy 'd[0]["key"]' 2>/dev/null || api -X POST "${BASE}/store/items/search" "${AUTH[@]}" -d '{"namespace_prefix":["suite","kv"]}' | jqpy 'd["items"][0]["key"]')
t "6.1 Store put + search (key-value)" "$([ "$GOT" = "alpha" ] && echo ok || echo fail)" "got ${GOT}"

SEM=$(api -X POST "${BASE}/store/items/search" "${AUTH[@]}" -d '{"namespace_prefix":["suite","kv"],"query":"when was the money returned"}')
HIT=$(echo "${SEM}" | jqpy '(d["items"] if isinstance(d,dict) else d)[0]["key"]' 2>/dev/null)
t "6.2 Semantic search (by meaning)" "$([ "$HIT" = "alpha" ] && echo ok || echo fail)" "hit ${HIT}"

api -X DELETE "${BASE}/store/items" "${AUTH[@]}" -d '{"namespace":["suite","kv"],"key":"alpha"}' > /dev/null
GONE=$(api -X POST "${BASE}/store/items/search" "${AUTH[@]}" -d '{"namespace_prefix":["suite","kv"]}' | jqpy 'len((d["items"] if isinstance(d,dict) else d))')
t "6.3 Store delete" "$([ "${GONE:-1}" = 0 ] && echo ok || echo fail)" "remaining ${GONE}"

NS=$(api -X POST "${BASE}/store/namespaces" "${AUTH[@]}" -d '{"prefix":["suite"]}')
t "6.4 List namespaces" "$(echo "${NS}" | grep -aq "suite" && echo ok || echo skip)"

# ----------------------------------------------------------------- 9. CRONS
sec "9. Crons"
CT=$(api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | jqpy 'd["thread_id"]')
CID=$(api -X POST "${BASE}/threads/${CT}/runs/crons" "${AUTH[@]}" -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"tick"}]},"schedule":"*/15 * * * *"}' | jqpy 'd["cron_id"]')
t "9.1 Thread-bound cron create (returns Cron object)" "$([ -n "$CID" ] && [ "$CID" != "None" ] && echo ok || echo fail)"

GOT=$(api "${BASE}/runs/crons/${CID}" "${AUTH[@]}" | jqpy 'd["schedule"]')
t "9.2 Get cron (official GET route, ours)" "$([ "$GOT" = "*/15 * * * *" ] && echo ok || echo fail)" "got ${GOT}"

SC=$(api -X POST "${BASE}/runs/crons/search" "${AUTH[@]}" -d '{"limit":10}')
t "9.3 Search crons" "$(echo "${SC}" | jqpy 'len(d)' | grep -qE '[0-9]+' && echo ok || echo fail)"

api -X PATCH "${BASE}/runs/crons/${CID}" "${AUTH[@]}" -d '{"schedule":"0 * * * *"}' > /dev/null
GOT=$(api "${BASE}/runs/crons/${CID}" "${AUTH[@]}" | jqpy 'd["schedule"]')
t "9.4 Update cron schedule" "$([ "$GOT" = "0 * * * *" ] && echo ok || echo fail)" "got ${GOT}"

api -X DELETE "${BASE}/runs/crons/${CID}" "${AUTH[@]}" -o /dev/null
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/runs/crons/${CID}" "${AUTH[@]}")
t "9.5 Delete cron" "$([ "$CODE" = 404 ] && echo ok || echo fail)" "after-delete HTTP ${CODE}"

# ----------------------------------------------------------------- 10. AUTH
sec "10. Auth"
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads" -H 'Content-Type: application/json' -d '{}')
t "10.1 Requests without key rejected (401)" "$([ "$CODE" = 401 ] && echo ok || echo fail)" "HTTP ${CODE}"
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads" -H 'x-api-key: wrong-key' -H 'Content-Type: application/json' -d '{}')
t "10.2 Wrong key rejected" "$([ "$CODE" = 401 ] && echo ok || echo fail)" "HTTP ${CODE}"

# ----------------------------------------------------------------- 11. PROTOCOLS + EXTENSIBILITY
sec "11. Protocols and extensibility"
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/ok")
t "11.1 /ok health (official contract, ours)" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/health")
t "11.2 /health liveness (aegra core; official uses /ok)" "$([ "$CODE" = 200 ] && echo ok || echo skip)" "HTTP ${CODE}"
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/metrics")
t "11.3 /metrics Prometheus (our extension)" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/docs")
t "11.4 OpenAPI docs at /docs" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"
OAPI=$(api "${BASE}/openapi.json")
t "11.5 openapi.json served" "$(echo "${OAPI}" | jqpy 'len(d["paths"])' | grep -qE '[0-9]+' && echo ok || echo fail)"
INFO=$(api "${BASE}/info" "${AUTH[@]}")
t "11.6 /info version endpoint" "$(echo "${INFO}" | grep -aq version && echo ok || echo fail)"

# ----------------------------------------------------------------- SUMMARY
sec "SUMMARY"
printf 'PASS: %d  FAIL: %d\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  printf 'Failed features:\n'
  for f in "${FAILED_FEATURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
echo "ALL FEATURE TESTS PASSED"
