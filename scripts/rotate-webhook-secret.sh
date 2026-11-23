#!/usr/bin/env bash
# Zero-downtime webhook secret rotation.
#
# Deliveries are HMAC-SHA256 signed with AGSER_WEBHOOK_SECRET
# (header: X-Agser-Signature: sha256=<hex>). To rotate without breaking any
# receiver:
#
#   1. Generate a new secret and set:
#        AGSER_WEBHOOK_SECRET           = <new>
#        AGSER_WEBHOOK_SECRET_PREVIOUS  = <old>
#      Deliveries now carry BOTH signatures
#      (X-Agser-Signature and X-Agser-Signature-Previous), so receivers that
#      still verify with the old secret keep working.
#   2. Migrate receivers to the new secret at your own pace.
#   3. Remove AGSER_WEBHOOK_SECRET_PREVIOUS and restart the platform.
#
# This script performs step 1 for the LOCAL stack (.env) and prints the exact
# AWS commands for a deployed stack.
set -euo pipefail
cd "$(dirname "$0")/.."

NEW=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')
CUR=$(grep -E '^AGSER_WEBHOOK_SECRET=' .env 2>/dev/null | cut -d= -f2- || true)
CUR=${CUR:-test-webhook-secret}

echo "new secret:  $NEW"
echo "old secret:  $CUR  (kept as _PREVIOUS during the rotation window)"
echo

if [ -f .env ]; then
  python3 - "$NEW" "$CUR" <<'PY'
import re, sys
new, old = sys.argv[1], sys.argv[2]
p = ".env"
s = open(p).read() if __import__("os").path.exists(p) else ""
s = re.sub(r"^AGSER_WEBHOOK_SECRET=.*$", f"AGSER_WEBHOOK_SECRET={new}", s, flags=re.M)
if "AGSER_WEBHOOK_SECRET=" not in s:
    s += f"\nAGSER_WEBHOOK_SECRET={new}\n"
s = re.sub(r"^AGSER_WEBHOOK_SECRET_PREVIOUS=.*$", f"AGSER_WEBHOOK_SECRET_PREVIOUS={old}", s, flags=re.M)
if "AGSER_WEBHOOK_SECRET_PREVIOUS=" not in s:
    s += f"AGSER_WEBHOOK_SECRET_PREVIOUS={old}\n"
open(p, "w").write(s)
print(f".env updated (rotation window open)")
PY
  echo "restart to apply:  docker compose up -d --force-recreate server"
else
  echo "no .env found — apply manually (see below)"
fi

cat <<'AWS'

AWS (deployed stack) — same rotation window, secrets live in the task definition:
  1. Store the new secret and keep the old one:
       aws secretsmanager put-secret-value --secret-id agser/webhook-secret \
         --secret-string "<NEW>"
  2. Add AGSER_WEBHOOK_SECRET_PREVIOUS=<OLD> to the task definition env
     (deploy/cdk), redeploy with ./scripts/deploy-image.sh
  3. Migrate receivers, then remove the _PREVIOUS variable and redeploy.

Verify both signatures are accepted:
  AGSER_WEBHOOK_SECRET=<NEW> AGSER_WEBHOOK_SECRET_PREVIOUS=<OLD> \
    python3 examples/webhook_receiver.py 9999
AWS
