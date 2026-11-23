"""Platform authentication for the Agent Server.

Wired in via the config file (`aegra.json` / `aegra.aws.json`) →
`"auth": {"path": "./auth.py:platform_auth"}`.

Two modes, chosen by environment:

**1. Single key (default — single-company use)**

    PLATFORM_API_KEY=<key>

Every caller authenticates as `platform-user`. All data is shared, which is
what an internal single-team deployment wants.

**2. Multiple keys → distinct identities (optional, tenant-style isolation)**

    PLATFORM_API_KEYS=keyA:alice,keyB:bob
    # or JSON:  PLATFORM_API_KEYS={"keyA":"alice","keyB":"bob"}

Each key authenticates as its own identity. The server core scopes every
resource (threads, assistants, runs, crons, store) by `user_id`, so each
identity only ever sees its own data — that is tenant isolation without any
schema change. `PLATFORM_API_KEY` still works alongside it if set.

Keys are compared in constant time (`hmac.compare_digest`). An unset key
configuration is a hard 500 — the server never serves open to the network.

Accepted transports (either):
  - `x-api-key: <key>`
  - `Authorization: Bearer <key>`

To extend to real SSO later, replace `authenticate()` with a JWT verifier and
add `@platform_auth.on` resource handlers for fine-grained authorization —
the shape below is already the LangGraph SDK `Auth` contract.
"""

import hmac
import json
import os

from langgraph_sdk.auth import Auth
from langgraph_sdk.auth.exceptions import HTTPException

platform_auth = Auth()

DEFAULT_IDENTITY = "platform-user"


def _load_keys() -> dict[str, str]:
    """Build the key → identity map from the environment.

    Supports both `PLATFORM_API_KEYS` (multi) and `PLATFORM_API_KEY` (single).
    Returns an empty dict when nothing is configured.
    """
    mapping: dict[str, str] = {}

    raw = os.environ.get("PLATFORM_API_KEYS", "").strip()
    if raw:
        parsed: dict[str, str] | None = None
        if raw.startswith("{"):
            try:
                obj = json.loads(raw)
                if isinstance(obj, dict):
                    parsed = {str(k): str(v) for k, v in obj.items()}
            except json.JSONDecodeError:
                parsed = None
        if parsed is None:
            # "keyA:alice,keyB:bob"
            parsed = {}
            for pair in raw.split(","):
                pair = pair.strip()
                if not pair:
                    continue
                if ":" not in pair:
                    continue
                key, identity = pair.split(":", 1)
                if key.strip() and identity.strip():
                    parsed[key.strip()] = identity.strip()
        mapping.update(parsed)

    single = os.environ.get("PLATFORM_API_KEY", "").strip()
    if single:
        mapping.setdefault(single, DEFAULT_IDENTITY)

    return mapping


def _extract_key(authorization: str | None, headers: dict | None) -> str | None:
    """Pull the presented key out of either supported transport."""
    if authorization:
        parts = authorization.split(" ", 1)
        if len(parts) == 2 and parts[0].lower() == "bearer":
            return parts[1].strip()
        # Allow the raw key in the Authorization header as well.
        return authorization.strip()
    if headers:
        for k, v in headers.items():
            name = k.decode() if isinstance(k, bytes) else k
            value = v.decode() if isinstance(v, bytes) else v
            if str(name).lower() == "x-api-key":
                return str(value).strip()
    return None


def _match_identity(provided: str, keys: dict[str, str]) -> str | None:
    """Constant-time lookup of the identity for a presented key."""
    matched: str | None = None
    for key, identity in keys.items():
        if hmac.compare_digest(provided, key):
            matched = identity
    return matched


@platform_auth.authenticate
async def authenticate(
    headers: dict | None = None,
    authorization: str | None = None,
) -> dict:
    """Validate the request and return the caller identity.

    Works under both dispatch styles: the platform server-core calls this
    handler with `headers` positionally; the official Agent Server dispatches
    supported parameter names as keywords.
    """
    keys = _load_keys()
    if not keys:
        # No key configured is a hard fail — never serve open to the network.
        raise HTTPException(
            500,
            "No API key configured: set PLATFORM_API_KEY (or PLATFORM_API_KEYS).",
        )

    provided = _extract_key(authorization, headers)
    if not provided:
        raise HTTPException(401, "Invalid or missing API key.")

    identity = _match_identity(provided, keys)
    if identity is None:
        raise HTTPException(401, "Invalid or missing API key.")

    return {
        "identity": identity,
        "display_name": identity,
        "is_authenticated": True,
    }
