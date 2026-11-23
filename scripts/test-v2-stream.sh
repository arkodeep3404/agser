#!/usr/bin/env bash
# Agent Protocol **v2 thread-scoped event streaming** — end-to-end client test.
#
#   ./scripts/test-v2-stream.sh                    # ours :8123
#   BASE=http://127.0.0.1:8124 ./scripts/test-v2-stream.sh   # official build
#
# Exercises POST /threads/{id}/stream/events the way a real v2 client does:
#   1. open the SSE stream on a thread (before any run exists)
#   2. start a run on that thread
#   3. assert protocol envelopes arrive (id: seq + data: JSON with a method)
#   4. assert the lifecycle channel reports running → completed
#   5. assert payload channels carry the graph output
#   6. reconnect with `since=<last seq>` and assert replay does not repeat
#      older sequence numbers (resume contract)
set -uo pipefail

BASE=${BASE:-http://127.0.0.1:8123}
API_KEY=${PLATFORM_API_KEY:-dev-key}
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

sec "v2 thread-scoped event stream"

ATTEMPTS=3
ATTEMPT_OK=0

run_scenario() {  # one full stream+run cycle; sets SC_* for assertions
  local attempt="$1"
  local TID STREAM SPID RID S FRAMES IDS METHODS LC HAS_CONTENT
  TID=$(api -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' | py 'import json,sys;print(json.load(sys.stdin)["thread_id"])')
  [ -n "$TID" ] || return 1
  SC_TID="$TID"

  STREAM="${TMP}/v2-${attempt}.sse"
  curl -s -N -m 150 -X POST "${BASE}/threads/${TID}/stream/events" "${AUTH[@]}" \
    -d '{"channels":["values","messages","lifecycle"]}' \
    -H 'Accept: text/event-stream' > "${STREAM}" 2>/dev/null &
  SPID=$!
  sleep 2

  # v2-native run start (payload channels are produced for v2 runs)
  RID=$(api -X POST "${BASE}/threads/${TID}/commands" "${AUTH[@]}" \
    -d '{"id":1,"method":"run.start","params":{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"v2-stream-probe"}]}}}' \
    | py 'import json,sys;d=json.load(sys.stdin);print((d.get("result") or {}).get("run_id",""))')
  SC_RID="$RID"
  [ -n "$RID" ] || { kill ${SPID} 2>/dev/null; return 1; }

  for i in $(seq 1 90); do
    S=$(api "${BASE}/threads/${TID}/runs/${RID}" "${AUTH[@]}" 2>/dev/null | py 'import json,sys;print(json.load(sys.stdin).get("status"))' 2>/dev/null || echo "?")
    [ "$S" = success ] && break
    sleep 2
  done
  for i in $(seq 1 40); do
    grep -aq "completed" "${STREAM}" 2>/dev/null && break
    sleep 1
  done
  sleep 1
  kill ${SPID} 2>/dev/null || true
  sleep 1

  SC_STREAM="${STREAM}"
  FRAMES=$(grep -c '^data:' "${STREAM}" 2>/dev/null); SC_FRAMES=${FRAMES:-0}
  IDS=$(grep -c '^id:' "${STREAM}" 2>/dev/null); SC_IDS=${IDS:-0}
  SC_METHODS=$(grep '^data:' "${STREAM}" | sed 's/^data: *//' | python3 -c '
import json, sys
methods = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    m = ev.get("method") or (ev.get("params") or {}).get("method")
    if m:
        methods.append(m)
print(",".join(sorted(set(methods))))
' 2>/dev/null)
  SC_LC=$(grep '^data:' "${STREAM}" | sed 's/^data: *//' | python3 -c '
import json, sys
events = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if (ev.get("method") or "") == "lifecycle":
        data = (ev.get("params") or {}).get("data") or {}
        if isinstance(data, dict) and data.get("event"):
            events.append(data["event"])
print(",".join(events))
' 2>/dev/null)
  SC_PONG=$(grep -ac "pong" "${STREAM}" 2>/dev/null); SC_PONG=${SC_PONG:-0}
  SC_LAST=$(grep '^id:' "${STREAM}" | sed 's/^id: *//' | tail -1)

  # success criteria for the retry: terminal lifecycle + payload content
  case "${SC_LC}" in *completed*) ;; *) return 1 ;; esac
  [ "${SC_PONG:-0}" -ge 1 ] || return 1
  return 0
}

for attempt in $(seq 1 ${ATTEMPTS}); do
  if run_scenario "${attempt}"; then ATTEMPT_OK=1; echo "  (attempt ${attempt}/${ATTEMPTS} captured the full event set)"; break; fi
  echo "  (attempt ${attempt}/${ATTEMPTS} missed terminal events — retrying)"
  sleep 2
done

t "V1 thread created" "$([ -n "${SC_TID:-}" ] && echo ok || echo fail)"
t "V2 run.start command accepted (v2-native)" "$([ -n "${SC_RID:-}" ] && echo ok || echo fail)"
t "V3 SSE frames received (data:)" "$([ "${SC_FRAMES:-0}" -ge 2 ] && echo ok || echo fail)" "frames=${SC_FRAMES:-0}"
t "V4 frames carry an event id (seq)" "$([ "${SC_IDS:-0}" -ge 1 ] && echo ok || echo fail)" "ids=${SC_IDS:-0}"
t "V5 envelopes are protocol events (method present)" "$([ -n "${SC_METHODS:-}" ] && echo ok || echo fail)" "methods=${SC_METHODS:-none}"
case "${SC_LC:-}" in
  *completed*) t "V6 lifecycle channel: run reached completed" ok ;;
  *running*)   t "V6 lifecycle channel: run reached completed" fail "saw only: ${SC_LC}" ;;
  *)           t "V6 lifecycle channel: run reached completed" fail "no lifecycle events (${SC_LC:-none})" ;;
esac
t "V7 payload channel carries the graph output" "$([ "${SC_PONG:-0}" -ge 1 ] && echo ok || echo fail)" "matches=${SC_PONG:-0}"

if [ -n "${SC_LAST:-}" ]; then
  curl -s -N -m 8 -X POST "${BASE}/threads/${SC_TID}/stream/events" "${AUTH[@]}" \
    -d "{\"channels\":[\"lifecycle\"],\"since\":${SC_LAST}}" > "${TMP}/resume.sse" 2>/dev/null || true
  OLD=$(grep '^id:' "${TMP}/resume.sse" 2>/dev/null | sed 's/^id: *//' | awk -v s="${SC_LAST}" '$1+0 <= s+0' | wc -l | tr -d ' ')
  t "V8 resume with since=<last seq> replays nothing older" "$([ "${OLD:-0}" = 0 ] && echo ok || echo fail)" "since=${SC_LAST} older_replayed=${OLD}"
else
  t "V8 resume with since=<last seq>" skip "no seq ids captured"
fi

sec "SUMMARY"
printf 'V2 STREAM: PASS %d  FAIL %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -gt 0 ] && { for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done; exit 1; }
echo "ALL V2 STREAM TESTS PASSED"
