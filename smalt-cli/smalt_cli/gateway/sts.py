"""Local OAuth2/OIDC-shaped token issuer.

Issues HS256-signed JWTs entirely in-process via the standard library. No
network calls: the gateway's tokens exist so the Azure SDK's credential path
has something wire-shaped to present, not to authenticate anything real.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from dataclasses import dataclass, field
from typing import Any, Mapping

__all__ = ["LocalSTS", "local_token"]


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(seg: str) -> bytes:
    return base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


def _json_b64(obj: Mapping[str, Any]) -> str:
    return _b64url(
        json.dumps(obj, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )


@dataclass
class LocalSTS:
    """client_credentials-style issuer of HS256 JWTs.

    ``oid``/``tid``/``iss``/``aud`` are configurable; ``exp``/``nbf`` derive
    from ``ttl_seconds`` at issue time.
    """

    issuer: str = "https://smalt.local/gateway/sts"
    audience: str = "https://smalt.local/gateway"
    tenant_id: str = "00000000-0000-0000-0000-000000000000"
    ttl_seconds: int = 3600
    secret: bytes = b"smalt-local-dev-secret"
    extra_claims: dict[str, Any] = field(default_factory=dict)

    def issue(
        self,
        client_id: str = "smalt-cli",
        *,
        ttl_seconds: int | None = None,
        oid: str | None = None,
        tid: str | None = None,
        extra: Mapping[str, Any] | None = None,
        now: float | None = None,
    ) -> str:
        ts = int(now if now is not None else time.time())
        ttl = self.ttl_seconds if ttl_seconds is None else ttl_seconds
        claims: dict[str, Any] = {
            "aud": self.audience,
            "iss": self.issuer,
            "tid": tid if tid is not None else self.tenant_id,
            "oid": oid if oid is not None else client_id,
            "nbf": ts,
            "exp": ts + ttl,
        }
        claims.update(self.extra_claims)
        if extra:
            claims.update(extra)
        header = {"alg": "HS256", "typ": "JWT"}
        payload_b64 = _json_b64(claims)
        signing_input = f"{_json_b64(header)}.{payload_b64}"
        sig = hmac.new(self.secret, signing_input.encode("ascii"), hashlib.sha256).digest()
        return f"{signing_input}.{_b64url(sig)}"

    def decode(self, token: str, *, verify: bool = True) -> tuple[dict[str, Any], dict[str, Any]]:
        """Return ``(header, claims)``; raises ``ValueError`` on bad signature
        or (when ``verify=True``) on ``exp``/``nbf`` violation."""
        try:
            h64, p64, s64 = token.split(".")
        except ValueError:
            raise ValueError("malformed token: expected 3 dot-separated segments") from None
        signing_input = f"{h64}.{p64}"
        expected = _b64url(
            hmac.new(self.secret, signing_input.encode("ascii"), hashlib.sha256).digest()
        )
        if not hmac.compare_digest(expected, s64):
            raise ValueError("signature verification failed")
        header = json.loads(_b64url_decode(h64))
        claims = json.loads(_b64url_decode(p64))
        if verify:
            now = int(time.time())
            if "exp" in claims and now >= claims["exp"]:
                raise ValueError("token expired")
            if "nbf" in claims and now < claims["nbf"]:
                raise ValueError("token not yet valid")
        return header, claims

    def client_credentials(self, client_id: str = "smalt-cli", **kwargs: Any) -> dict[str, Any]:
        """OAuth2 client_credentials token response shape."""
        return {
            "token_type": "Bearer",
            "expires_in": kwargs.pop("ttl_seconds", None) or self.ttl_seconds,
            "access_token": self.issue(client_id, **kwargs),
        }


def local_token(**kwargs: Any) -> str:
    """Convenience: issue one token from a throwaway ``LocalSTS``."""
    return LocalSTS().issue(**kwargs)
