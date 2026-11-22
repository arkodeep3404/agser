"""Minimal webhook receiver for run-completion webhooks.

The Agent Server fires a POST to each assistant's configured webhook URL when
its runs finish (success, error, or timeout). Point the server at this
receiver to inspect payloads:

    python examples/webhook_receiver.py 9999

Then allow-list the host in LANGGRAPH_WEBHOOKS (see .env.example), set the
webhook on an assistant:

    curl -X PATCH $BASE/assistants/$AID -H "x-api-key: $KEY" \\
      -H 'Content-Type: application/json' \\
      -d '{"metadata":{"...":null}}'   # webhook field per your server version

and run something on that assistant — the receiver prints each event.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 — stdlib naming
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b"{}"
        print("webhook:", self.path)
        print(json.dumps(json.loads(body), indent=2)[:2000])
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):  # silence default request log
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
    print(f"webhook receiver on :{port}")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
