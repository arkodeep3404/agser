#!/usr/bin/env bash
# Local stack: build the image and bring up Postgres + Redis + Agent Server.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d --build
echo
echo "  server     http://127.0.0.1:8123"
echo "  api key    \${PLATFORM_API_KEY:-dev-key}"
echo "  next       ./scripts/verify.sh"
