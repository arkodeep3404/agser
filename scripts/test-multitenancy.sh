#!/usr/bin/env bash
# Optional multi-key isolation check.
#
# The server supports two auth modes (see auth.py):
#   * PLATFORM_API_KEY   → one shared identity (default, single-company)
#   * PLATFORM_API_KEYS  → key:identity pairs, each identity fully isolated
#
# This suite verifies isolation when the multi-key mode is configured, and
# SKIPs cleanly when it is not (so it is safe in the normal gate).
#
#   PLATFORM_API_KEYS="keyA:alice,keyB:bob" docker compose up -d --force-recreate server
#   KEY_A=keyA KEY_B=keyB ./scripts/test-multitenancy.sh
set -uo pipefail

BASE=${BASE:-http://127.0.0.1:8123}
KEY_A=${KEY_A:-tenant-a-key}
KEY_B=${KEY_B:-tenant-b-key}
PASS=0; FAIL=0; FAILED=()

t() {
  if [ "$2" = ok ]; then PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"
  elif [ "$2" = skip ]; then printf '  \033[33mSKIP\033[0m %s %s\n' "$1" "${3:+— ${3}}"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31mFAIL\033[0m %s %s\n' "$1" "${3:+— ${3}}"; fi
}
api() { curl -s -m "${API_TIMEOUT:-30}" "$@"; }
py() { python3 -c "$1" 2>/dev/null; }
sec() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

sec "multi-key isolation"

A=(-H "x-api-key: ${KEY_A}" -H 'Content-Type: application/json')
B=(-H "x-api-key: ${KEY_B}" -H 'Content-Type: application/json')

# Probe: is multi-key mode actually configured?
CODE_A=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads" "${A[@]}" -d '{}')
CODE_B=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads" "${B[@]}" -d '{}')
if [ "$CODE_A" != 200 ] || [ "$CODE_B" != 200 ]; then
  t "multi-key mode configured" skip "keyA→HTTP ${CODE_A}, keyB→HTTP ${CODE_B} (single-key mode)"
  sec "SUMMARY"; printf 'TENANCY: SKIP (not configured)\n'; exit 0
fi
t "both keys authenticate" ok

# A's thread
TID=$(api -X POST "${BASE}/threads" "${A[@]}" -d '{"metadata":{"tenant":"a"}}' | py 'import json,sys;print(json.load(sys.stdin)["thread_id"])')
t "tenant A created a thread" "$([ -n "$TID" ] && echo ok || echo fail)"

# B must NOT be able to read it
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/threads/${TID}" "${B[@]}")
t "tenant B cannot read A's thread (404)" "$([ "$CODE" = 404 ] && echo ok || echo fail)" "HTTP ${CODE}"

# B must NOT see it in search
HITS=$(api -X POST "${BASE}/threads/search" "${B[@]}" -d '{"metadata":{"tenant":"a"},"limit":10}' | py 'import json,sys;print(len(json.load(sys.stdin)))')
t "tenant B's search excludes A's thread" "$([ "${HITS:-x}" = 0 ] && echo ok || echo fail)" "hits=${HITS}"

# A still can
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/threads/${TID}" "${A[@]}")
t "tenant A can read its own thread" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

# B must NOT be able to run on A's thread
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads/${TID}/runs/wait" "${B[@]}" \
  -d '{"assistant_id":"ping","input":{"messages":[{"role":"user","content":"x"}]}}')
t "tenant B cannot run on A's thread" "$([ "$CODE" = 404 ] || [ "$CODE" = 403 ] && echo ok || echo fail)" "HTTP ${CODE}"

# B must NOT be able to delete A's thread
CODE=$(api -o /dev/null -w '%{http_code}' -X DELETE "${BASE}/threads/${TID}" "${B[@]}")
t "tenant B cannot delete A's thread" "$([ "$CODE" = 404 ] || [ "$CODE" = 403 ] && echo ok || echo fail)" "HTTP ${CODE}"

# A's thread still intact
CODE=$(api -o /dev/null -w '%{http_code}' "${BASE}/threads/${TID}" "${A[@]}")
t "A's thread survived B's attempts" "$([ "$CODE" = 200 ] && echo ok || echo fail)" "HTTP ${CODE}"

# A stranger key is rejected
CODE=$(api -o /dev/null -w '%{http_code}' -X POST "${BASE}/threads" -H 'x-api-key: not-a-key' -H 'Content-Type: application/json' -d '{}')
t "unknown key rejected (401)" "$([ "$CODE" = 401 ] && echo ok || echo fail)" "HTTP ${CODE}"

sec "SUMMARY"
printf 'TENANCY: PASS %d  FAIL %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -gt 0 ] && { for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done; exit 1; }
echo "ALL MULTI-KEY ISOLATION TESTS PASSED"
