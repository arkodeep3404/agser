"""OpenAI-compatible fake embeddings server — deterministic, offline.

Aegra's semantic store takes a provider string (langchain init_embeddings
format), which is the right production design — but local/CI runs have no
embeddings credentials. This server implements POST /v1/embeddings with
deterministic hashed vectors (same scheme as agents/embeddings.py
HashedEmbeddings), so semantic search works identically offline and online.

Run: python examples/fake_embeddings_server.py [port] [dims]
"""

import hashlib
import json
import math
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIMS = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8010


def embed(text) -> list[float]:
    if isinstance(text, list):
        # The OpenAI SDK may send pre-tokenized input (list of token ids).
        # Hash the token-id sequence — deterministic for the same text.
        text = " ".join(str(t) for t in text)
    vec = [0.0] * DIMS
    for token in str(text).lower().split():
        digest = hashlib.sha256(token.encode("utf-8")).digest()
        idx = int.from_bytes(digest[:4], "big") % DIMS
        vec[idx] += 1 if digest[4] % 2 else -1
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]


class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            self._json(200, {"status": "ok"})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if self.path.rstrip("/") != "/v1/embeddings":
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        texts = req.get("input", [])
        if isinstance(texts, str):
            texts = [texts]
        self._json(200, {
            "object": "list",
            "model": req.get("model", "fake"),
            "data": [
                {"object": "embedding", "index": i, "embedding": embed(t)}
                for i, t in enumerate(texts)
            ],
        })

    def log_message(self, *args):  # silence default request log
        pass


if __name__ == "__main__":
    print(f"fake embeddings on :{PORT} dims={DIMS}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
