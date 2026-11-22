"""Embeddings for the store's semantic search (cross-thread long-term memory).

Provider is a deployment choice — EMBEDDINGS_PROVIDER:
  - "bedrock" (AWS default): Amazon Bedrock Titan — embeddings stay in-account
    via the task's IAM role, no static keys.
  - "openai": OpenAI text-embedding-3-large (dimensions=1024, needs
    OPENAI_API_KEY).
  - "fake": deterministic offline embeddings for local tests and CI — no
    network, no keys.

All providers emit 1024-dim vectors to match `store.index.dims` in
langgraph.json. Switching providers on a live deployment is possible: vectors
are re-embedded on write, but stale items keep old embeddings until rewritten.
"""

import hashlib
import math
import os

from langchain_core.embeddings import Embeddings

DIMS = 1024


class HashedEmbeddings(Embeddings):
    """Deterministic bag-of-words hashing embeddings (offline, for tests/CI)."""

    def _embed(self, text: str) -> list[float]:
        vec = [0.0] * DIMS
        tokens = text.lower().split()
        if not tokens:
            return vec
        for token in tokens:
            digest = hashlib.sha256(token.encode("utf-8")).digest()
            idx = int.from_bytes(digest[:4], "big") % DIMS
            sign = 1 if digest[4] % 2 else -1
            vec[idx] += sign
        norm = math.sqrt(sum(v * v for v in vec)) or 1.0
        return [v / norm for v in vec]

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return [self._embed(t) for t in texts]

    def embed_query(self, text: str) -> list[float]:
        return self._embed(text)


def get_embeddings() -> Embeddings:
    """Factory referenced by langgraph.json → store.index.embed."""
    provider = os.environ.get("EMBEDDINGS_PROVIDER", "bedrock").lower()
    if provider == "fake":
        return HashedEmbeddings()
    if provider == "openai":
        from langchain_openai import OpenAIEmbeddings

        return OpenAIEmbeddings(
            model=os.environ.get("OPENAI_EMBEDDING_MODEL", "text-embedding-3-large"),
            dimensions=DIMS,
        )
    # Default: Bedrock — in-account, IAM-based.
    from langchain_aws import BedrockEmbeddings

    return BedrockEmbeddings(
        model_id=os.environ.get(
            "BEDROCK_EMBEDDING_MODEL", "amazon.titan-embed-text-v2:0"
        ),
        region_name=os.environ.get("AWS_REGION") or None,
    )
