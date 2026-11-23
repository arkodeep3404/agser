"""Webhook receiver with HMAC-SHA256 signature verification.

    AGSER_WEBHOOK_SECRET=test-webhook-secret python examples/webhook_receiver.py 9999

The Agent Server signs every delivery:
    X-Agser-Signature: sha256=<hexdigest of HMAC_SHA256(secret, raw body)>
"""

import hashlib
import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = os.environ.get("AGSER_WEBHOOK_SECRET", "")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b"{}"
        sig = self.headers.get("X-Agser-Signature", "")
        expected = "sha256=" + hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest() if SECRET else None
        valid = (sig == expected) if expected is not None else None
        print(f"webhook: {self.path} signature={'VALID' if valid else ('MISSING' if valid is None else 'INVALID')}")
        payload = json.loads(body)
        print("  run:", payload.get("run_id"), "status:", payload.get("status"), "thread:", payload.get("thread_id"))
        with open(os.environ.get("WEBHOOK_OUT", "/tmp/webhook-out.json"), "w") as f:
            json.dump({"signature": sig, "valid": valid, "payload": payload}, f)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
    print(f"webhook receiver on :{port} (secret {'set' if SECRET else 'NOT set'})")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
