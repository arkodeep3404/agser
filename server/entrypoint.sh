#!/usr/bin/env bash
# Entrypoint: assembles DATABASE_URI from parts when running on AWS
# (RDS credentials arrive as separate secret-injected env vars), then runs
# the Agent Server — or any command passed through (e.g. the watchdog).
set -euo pipefail

if [ -n "${DB_HOST:-}" ] && [ -n "${DB_PASSWORD:-}" ]; then
  export DATABASE_URI="postgres://${DB_USER:-postgres}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT:-5432}/${DB_NAME:-langgraph}"
fi

if [ "$#" -eq 0 ]; then
  set -- python -m langgraph_api.cli \
    --config langgraph.json \
    --port "${PORT:-8123}" \
    --host 0.0.0.0 \
    --no-reload \
    --n-jobs-per-worker "${N_JOBS_PER_WORKER:-10}"
fi

exec "$@"
