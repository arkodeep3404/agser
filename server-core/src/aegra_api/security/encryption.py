"""agser (ours): AES-256-GCM encryption at rest for checkpoints.

Implements the official Agent Server contract: set ``LANGGRAPH_AES_KEY``
(16/24/32 bytes, or any string — hashed to 32 bytes) and every checkpoint
blob (channel values, metadata, pending writes) is encrypted with
AES-256-GCM before it touches Postgres, and transparently decrypted on
read. Blob layout:

    MAGIC(16) | nonce(12) | ciphertext+tag

The magic marker makes loads backward-compatible: pre-encryption plaintext
blobs still load (no key required), and encrypted blobs are recognized
even before any key is validated. AAD binds the blob to its type string so
swapping payloads between columns fails closed.

NOT covered (deliberately, documented in docs/FEATURE-VERIFICATION.md):
store items (JSONB) — covered by RDS storage encryption + KMS; thread /
assistant / run metadata — same compensating controls.
"""

from __future__ import annotations

import hashlib
import os

from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer

MAGIC = b"AGSER-AESGCM1\x00\x00"  # 16 bytes, versioned marker


def derive_key(secret: str) -> bytes:
    raw = secret.encode("utf-8")
    if len(raw) in (16, 24, 32):
        return raw
    return hashlib.sha256(raw).digest()


def maybe_encrypted_serde(secret: str | None) -> JsonPlusSerializer | None:
    """Return an encrypting serializer when a key is configured, else None."""
    if not secret:
        return None
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    key = derive_key(secret)
    aes = AESGCM(key)

    class EncryptedSerializer(JsonPlusSerializer):
        def dumps_typed(self, obj):  # type: ignore[override]
            type_str, blob = super().dumps_typed(obj)
            nonce = os.urandom(12)
            ct = aes.encrypt(nonce, blob, type_str.encode("utf-8"))
            return type_str, MAGIC + nonce + ct

        def loads_typed(self, data):  # type: ignore[override]
            type_str, blob = data
            if blob[: len(MAGIC)] == MAGIC:
                body = blob[len(MAGIC) :]
                nonce, ct = body[:12], body[12:]
                blob = aes.decrypt(nonce, ct, type_str.encode("utf-8"))
            return super().loads_typed((type_str, blob))

    return EncryptedSerializer()
