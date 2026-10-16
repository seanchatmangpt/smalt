"""Local OAuth2/OIDC-shaped token issuer.

Issues HS256-signed JWTs via ``pyjwt`` (the standard library of record for
JWT sign/verify). No network calls: the gateway's tokens exist so the Azure
SDK's credential path has something wire-shaped to present, not to
authenticate anything real.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Mapping

import jwt

__all__ = ["LocalSTS", "local_token"]


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
        return jwt.encode(claims, key=self.secret, algorithm="HS256", headers={"typ": "JWT"})

    def decode(self, token: str, *, verify: bool = True) -> tuple[dict[str, Any], dict[str, Any]]:
        """Return ``(header, claims)``; raises ``ValueError`` on bad signature
        or (when ``verify=True``) on ``exp``/``nbf`` violation."""
        try:
            header = jwt.get_unverified_header(token)
            claims = jwt.decode(
                token,
                key=self.secret,
                algorithms=["HS256"],
                options={
                    "verify_aud": False,
                    "verify_iss": False,
                    "verify_exp": False,
                    "verify_nbf": False,
                },
            )
        except jwt.InvalidSignatureError:  # subclass of DecodeError: match first
            raise ValueError("signature verification failed") from None
        except jwt.DecodeError:
            raise ValueError("malformed token: expected 3 dot-separated segments") from None
        except jwt.InvalidTokenError as exc:  # structural failures (bad b64, bad json)
            raise ValueError(f"malformed token: {exc}") from None
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
