#!/usr/bin/env bash
# End-to-end verification of the running platform (local compose or AWS ALB).
# Exercises: health, auth, info, threads, sync/stream/background runs,
# durable state, crons, store, metrics.
set -euo pipefail

BASE=${BASE:-http://127.0.0.1:8123}
API_KEY=${PLATFORM_API_KEY:-dev-key}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m  %s\n' "$*"; }
AUTH=(-H "x-api-key: ${API_KEY}" -H 'Content-Type: application/json')

say "GET /ok"
curl -sf -m 10 "${BASE}/ok" -o "${TMP}/ok.json" || fail "server not reachable at ${BASE}"
grep -q '"ok":true' "${TMP}/ok.json" || fail "not healthy"
ok "healthy"

say "auth: request WITHOUT key must be rejected"
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "${BASE}/threads" -X POST \
  -H 'Content-Type: application/json' -d '{}' || true)
[ "${code}" = "401" ] || [ "${code}" = "403" ] || fail "expected 401/403 without key, got ${code}"
ok "rejected (${code})"

say "GET /info"
curl -sf -m 10 "${BASE}/info" "${AUTH[@]}" -o "${TMP}/info.json" || fail "/info failed"
python3 - "${TMP}/info.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  server {d.get('version')}  langgraph {d.get('langgraph_py_version')}  host {d.get('host',{}).get('kind')}")
print(f"  flags: {d.get('flags')}")
PY

say "POST /threads"
curl -sf -m 10 -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' -o "${TMP}/thread.json" \
  || fail "thread creation failed"
TID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["thread_id"])' "${TMP}/thread.json")
ok "thread_id ${TID}"

say "POST /threads/{id}/runs/wait  (graph: ping)"
curl -sf -m 30 -X POST "${BASE}/threads/${TID}/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"hello"}]}}' \
  -o "${TMP}/run.json" || fail "run failed"
python3 - "${TMP}/run.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
last = d["messages"][-1]
assert "pong" in last["content"], f"unexpected reply: {last}"
print(f"  reply: {last['content']}")
PY

say "POST /threads/{id}/runs/stream  (SSE)"
curl -s -m 30 -N -X POST "${BASE}/threads/${TID}/runs/stream" "${AUTH[@]}" \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"stream-me"}]},"stream_mode":["messages-tuple","values"]}' \
  -o "${TMP}/stream.txt" || fail "streaming run failed"
grep -q "event:" "${TMP}/stream.txt" || fail "no SSE events in stream"
ok "$(grep -c '^event:' "${TMP}/stream.txt") SSE events"

say "POST /threads/{id}/runs  (background run through the queue)"
RID=$(curl -sf -m 10 -X POST "${BASE}/threads/${TID}/runs" "${AUTH[@]}" \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"bg"}]}}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])') \
  || fail "background run creation failed"
for i in $(seq 1 30); do
  st=$(curl -sf -m 10 "${BASE}/threads/${TID}/runs/${RID}" "${AUTH[@]}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null || echo "pending")
  [ "${st}" = "success" ] && break
  sleep 1
done
[ "${st}" = "success" ] || fail "background run did not finish (status: ${st})"
ok "run ${RID} → success"

say "GET /threads/{id}/state  (checkpoint persisted)"
curl -sf -m 10 "${BASE}/threads/${TID}/state" "${AUTH[@]}" -o "${TMP}/state.json" || fail "state fetch failed"
python3 - "${TMP}/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
n = len(d.get("values", {}).get("messages", []))
cp = d.get("checkpoint", {}).get("checkpoint_id")
assert n >= 2, "expected persisted messages"
print(f"  messages: {n}  checkpoint: {str(cp)[:26]}...")
PY

say "crons: create → get → delete"
CID=$(curl -sf -m 10 -X POST "${BASE}/threads/${TID}/runs/crons" "${AUTH[@]}" \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"tick"}]},"schedule":"*/15 * * * *"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["cron_id"])') \
  || fail "cron creation failed"
curl -sf -m 10 "${BASE}/runs/crons/${CID}" "${AUTH[@]}" -o "${TMP}/cronget.json" || fail "cron get failed"
python3 - "${TMP}/cronget.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schedule"] == "*/15 * * * *"
print(f"  cron {d['cron_id']} schedule {d['schedule']}")
PY
curl -sf -m 10 -X DELETE "${BASE}/runs/crons/${CID}" "${AUTH[@]}" -o /dev/null || fail "cron delete failed"
ok "cron lifecycle ok"

say "store: put → search"
curl -sf -m 10 -X PUT "${BASE}/store/items" "${AUTH[@]}" \
  -d '{"namespace":["verify","probe"],"key":"k","value":{"ok":true}}' -o /dev/null \
  || fail "store put failed"
curl -sf -m 10 -X POST "${BASE}/store/items/search" "${AUTH[@]}" \
  -d '{"namespace_prefix":["verify"]}' -o "${TMP}/store.json" || fail "store search failed"
python3 - "${TMP}/store.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
items = d["items"] if isinstance(d, dict) else d
assert any(i["key"] == "k" for i in items), "stored item not found"
print(f"  {len(items)} item(s) found")
PY

say "GET /metrics  (Prometheus)"
curl -sf -m 10 "${BASE}/metrics" "${AUTH[@]}" -o "${TMP}/metrics.txt" || fail "metrics failed"
grep -q "python_gc_objects_collected_total" "${TMP}/metrics.txt" || fail "unexpected metrics payload"
ok "$(wc -l < "${TMP}/metrics.txt") metric lines"

say "human-in-the-loop: interrupt → resume (graph: approval)"
HTID=$(curl -sf -m 10 -X POST "${BASE}/threads" "${AUTH[@]}" -d '{}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["thread_id"])') \
  || fail "HITL thread creation failed"
code=$(curl -s -m 30 -o "${TMP}/hitl.json" -w '%{http_code}' -X POST \
  "${BASE}/threads/${HTID}/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"approval","input":{"messages":[{"role":"user","content":"go"}]}}') \
  || true
HTHR=$(curl -sf -m 10 "${BASE}/threads/${HTID}" "${AUTH[@]}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
[ "${HTHR}" = "interrupted" ] || fail "expected thread status 'interrupted', got ${HTHR}"
ok "thread interrupted at human gate"
curl -sf -m 30 -X POST "${BASE}/threads/${HTID}/runs/wait" "${AUTH[@]}" \
  -d '{"assistant_id":"approval","command":{"resume":{"approved":true}}}' \
  -o "${TMP}/hitl2.json" || fail "resume failed"
python3 - "${TMP}/hitl2.json" "${TMP}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
msgs = [m["content"] for m in d["messages"]]
assert any("approved=True" in m for m in msgs), f"no approval message: {msgs}"
assert sum(1 for m in msgs if m.startswith("prep:")) == 1, "prep ran more than once!"
print("  resumed with human approval; prep executed exactly once")
PY

say "store: semantic search (query by meaning)"
curl -sf -m 10 -X PUT "${BASE}/store/items" "${AUTH[@]}" \
  -d '{"namespace":["memory","acme"],"key":"theme","value":{"text":"prefers dark interfaces and concise answers"}}' \
  -o /dev/null || fail "semantic store put failed"
curl -sf -m 10 -X POST "${BASE}/store/items/search" "${AUTH[@]}" \
  -d '{"namespace_prefix":["memory"],"query":"ui appearance preferences"}' \
  -o "${TMP}/sem.json" || fail "semantic search failed"
python3 - "${TMP}/sem.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
items = d["items"] if isinstance(d, dict) else d
hits = [i for i in items if i["key"] == "theme"]
assert hits, f"semantic search did not find the item"
score = hits[0].get("score")
print(f"  found by meaning (score={score:.3f})" if score is not None else "  found by meaning")
PY

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  say "POST /threads/{id}/runs/wait  (graph: research, real deep agent)"
  curl -sf -m 180 -X POST "${BASE}/threads/${TID}/runs/wait" "${AUTH[@]}" \
    -d '{"assistant_id":"research","input":{"messages":[{"role":"user","content":"In one sentence: what can our billing-api do? Use the catalog tool, then stop."}]}}' \
    -o "${TMP}/deep.json" || fail "deep agent run failed"
  python3 - "${TMP}/deep.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  deep agent replied: {d['messages'][-1]['content'][:200]}")
PY
else
  say "deep agent (graph: research)"
  ok "skipped — set ANTHROPIC_API_KEY to exercise it"
fi

say "PASS — platform verified: health, auth, threads, runs (sync/stream/bg), state, crons, store, metrics"
