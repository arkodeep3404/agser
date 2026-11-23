#!/usr/bin/env bash
# Upgrade gate — proves a dependency upgrade didn't break anything.
#
#   1. Rebuild the server image with the new dependency set
#   2. Run the full conformance suites against it:
#        verify.sh         — platform smoke (health, auth, runs, crons, store)
#        test-features.sh  — 62-feature official-contract conformance
#        test-failures.sh  — crash/network-drop/cancel/parallel, exactly-once
#
# Usage:
#   ./scripts/upgrade-check.sh                    # rebuild + full gate
#   BASE=http://<target> ./scripts/upgrade-check.sh --no-rebuild   # gate an already-running server
#
# If the gate fails:
#   - server/requirements.lock.txt records the last-known-good set —
#     restore it to roll back (it is a reference, not enforced in builds).
set -uo pipefail
cd "$(dirname "$0")/.."

REBUILD=1
[ "${1:-}" = "--no-rebuild" ] && REBUILD=0

RED=$'\033[31m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
declare -a RESULTS=()

run_suite() {
  local name="$1"; shift
  printf '%s== %s ==%s\n' "$BOLD" "$name" "$OFF"
  if "$@" > "/tmp/upgrade-$(echo "$name" | tr ' /' '__').log" 2>&1; then
    printf '%s   PASS%s\n' "$GREEN" "$OFF"
    RESULTS+=("PASS  $name")
    return 0
  else
    printf '%s   FAIL%s  (log: /tmp/upgrade-%s.log)\n' "$RED" "$OFF" "$(echo "$name" | tr ' /' '__')"
    RESULTS+=("FAIL  $name")
    return 1
  fi
}

if [ "${REBUILD}" = 1 ]; then
  printf '%s== Rebuilding server image (fresh dependency resolution) ==%s\n' "$BOLD" "$OFF"
  docker compose build server >/dev/null 2>&1 || { echo "${RED}image build failed${OFF}"; exit 1; }
  docker compose up -d --force-recreate server >/dev/null 2>&1
  sleep 45
  curl -sf -m 10 http://127.0.0.1:8123/ok >/dev/null || { echo "${RED}server did not come up${OFF}"; exit 1; }
fi

FAILED=0
run_suite "verify" ./scripts/verify.sh || FAILED=1
run_suite "feature conformance" ./scripts/test-features.sh || FAILED=1
run_suite "failure injection" ./scripts/test-failures.sh || FAILED=1
run_suite "human-in-the-loop lifecycle" ./scripts/test-hitl.sh || FAILED=1

printf '\n%s== UPGRADE GATE: %s ==%s\n' "$BOLD" "$([ $FAILED = 0 ] && echo GREEN || echo BLOCKED)" "$OFF"
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
exit $FAILED
