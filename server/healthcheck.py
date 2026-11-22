"""Container healthcheck used by both Docker HEALTHCHECK and ECS.

ECS ignores Dockerfile HEALTHCHECK — the CDK task definition points at this
same script so local and AWS behave identically.
"""

import json
import os
import sys
import urllib.request

try:
    port = os.environ.get("PORT", "8123")
    with urllib.request.urlopen(
        f"http://127.0.0.1:{port}/ok", timeout=3
    ) as resp:
        payload = json.load(resp)
    sys.exit(0 if payload.get("ok") else 1)
except Exception:
    sys.exit(1)
