#!/usr/bin/env bash
# Tear down the local stack (add -v to wipe Postgres data).
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down "$@"
