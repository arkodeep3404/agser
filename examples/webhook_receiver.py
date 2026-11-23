"""Webhook receiver with HMAC-SHA256 signature verification (rotation-aware).

    AGSER_WEBHOOK_SECRET=test-webhook-secret python examples/webhook_receiver.py 9999

The Agent Server signs every delivery:
    X-Agser-Signature:          sha256=<hmac of raw body with the current secret>
    X-Agser-Signature-Previous: sha256=<hmac with the previous secret>   (rotation window only)

During a secret rotation the server sends BOTH, so a receiver that has not
been migrated yet keeps verifying. Accept either one:

    AGSER_WEBHOOK_SECRET=<new> AGSER_WEBHOOK_SECRET_PREVIOUS=<old> \
        python examples/webhook_receiver.py 9999
"""

import hashlib
import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = os.environ.get("AGSER_WEBHOOK_SECRET", "")
PREVIOUS = os.environ.get("AGSER_WEBHOOK_SECRET_PREVIOUS", "")


def _sig(secret: str, body: bytes) -> str:
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b"{}"
        sig = self.headers.get("X-Agser-Signature", "")
        sig_prev = self.headers.get("X-Agser-Signature-Previous", "")

        # Rotation-safe verification: accept EITHER signature header against
        # EITHER secret this receiver knows. A receiver that has not been
        # migrated yet only knows the OLD secret — the server puts the old
        # signature in X-Agser-Signature-Previous, so it still validates.
        verdict = "NO-SECRET-CONFIGURED"
        matched = None
        known = [(name, sec) for name, sec in (("current", SECRET), ("previous", PREVIOUS)) if sec]
        if known:
            verdict = "INVALID"
            for header_name, presented in (("X-Agser-Signature", sig),
                                           ("X-Agser-Signature-Previous", sig_prev)):
                if not presented:
                    continue
                for secret_name, secret in known:
                    if hmac.compare_digest(presented, _sig(secret, body)):
                        verdict, matched = "VALID", f"{header_name} vs {secret_name} secret"
                        break
                if matched:
                    break

        print(f"webhook: {self.path} signature={verdict}"
              + (f" (matched {matched})" if matched else ""))
        payload = json.loads(body)
        print("  run:", payload.get("run_id"), "status:", payload.get("status"),
              "thread:", payload.get("thread_id"))
        with open(os.environ.get("WEBHOOK_OUT", "/tmp/webhook-out.json"), "w") as f:
            json.dump({"signature": sig, "signature_previous": sig_prev,
                       "valid": verdict == "VALID", "matched": matched,
                       "payload": payload}, f)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
    print(f"webhook receiver on :{port} "
          f"(secret {'set' if SECRET else 'NOT set'}, "
          f"previous {'set' if PREVIOUS else 'unset'})")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
