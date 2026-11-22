"""Platform authentication for the Agent Server.

Wired in via `langgraph.json` → `"auth": {"path": "./auth.py:platform_auth"}`.

Accepts a single shared API key (company-internal use), supplied as either:
  - `Authorization: Bearer <key>` header
  - `x-api-key: <key>` header

The key is read from the `PLATFORM_API_KEY` environment variable. In AWS it is
injected from Secrets Manager; locally it comes from the compose environment.

To extend per-user auth (OIDC, corporate SSO), replace `authenticate()` with a
JWT verification handler and add `@platform_auth.on` resource handlers for
fine-grained access control. See docs/RUNBOOK.md → "Authentication".
"""

import hmac
import os

from langgraph_sdk.auth import Auth
from langgraph_sdk.auth.exceptions import HTTPException

platform_auth = Auth()


def _extract_key(authorization: str | None, headers: dict | None) -> str | None:
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
            if name.lower() == "x-api-key":
                return value.strip()
    return None


@platform_auth.authenticate
async def authenticate(
    headers: dict | None = None,
    authorization: str | None = None,
) -> dict:
    """Validate the request and return the caller identity.

    Accepts the key from `Authorization: Bearer <key>` or `x-api-key`.
    Works under both dispatch styles: the platform server-core calls this
    handler with `headers` positionally; the official Agent Server dispatches
    supported parameter names as keywords.
    """
    expected = os.environ.get("PLATFORM_API_KEY", "")
    if not expected:
        # No key configured is a hard fail — never serve open to the network.
        raise HTTPException(
            500, "PLATFORM_API_KEY is not configured on the server."
        )

    provided = _extract_key(authorization, headers)
    if not provided or not hmac.compare_digest(provided, expected):
        raise HTTPException(401, "Invalid or missing API key.")

    return {"identity": "platform-user", "display_name": "platform-user", "is_authenticated": True}
