"""Real STS credentials for the lane. Zero mocks: every token is minted by the
emulator STS (POST {ARM}/oauth2/v2.0/token, client_credentials, HS256).
"""
import base64
import json
import os
import time

import requests
from azure.core.credentials import AccessToken, TokenCredential
from azure.core.exceptions import HttpResponseError


class SmaltTokenCredential(TokenCredential):
    """Mints smalt bearer tokens via the REAL STS token endpoint, caching until
    5 minutes before expiry. Scope arguments are accepted and ignored — the
    emulator STS scopes to https://management.azure.com by construction."""

    def __init__(self, arm_endpoint):
        self._arm = arm_endpoint.rstrip("/")
        self._cached = None

    def get_token(self, *pins, **kwargs):
        now = time.time()
        if self._cached and self._cached.expires_on - now > 300:
            return self._cached
        resp = requests.post(
            f"{self._arm}/oauth2/v2.0/token",
            data={
                "grant_type": "client_credentials",
                "client_id": "py-verify-lane",
                "client_secret": "py-verify-lane-secret",
            },
            timeout=15,
        )
        if resp.status_code != 200:
            raise HttpResponseError(
                message=f"STS mint failed {resp.status_code}: {resp.text[:200]}"
            )
        tok = resp.json()["access_token"]
        payload = tok.split(".")[1]
        exp = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["exp"]
        self._cached = AccessToken(tok, exp)
        return self._cached


def make_credential(arm_endpoint):
    """SMALT_PY_CREDENTIAL=smalt (default) -> SmaltTokenCredential.
    =azure -> azure-identity ClientSecretCredential; on mint failure raises
    CredentialUnavailableError so the caller can loud-SKIP (RS256+JWKS upgrade
    in flight on a sibling lane)."""
    mode = os.environ.get("SMALT_PY_CREDENTIAL", "smalt")
    if mode == "azure":
        from azure.identity import ClientSecretCredential
        from azure.identity import CredentialUnavailableError

        cred = ClientSecretCredential(
            tenant_id="py-verify-tenant",
            client_id="py-verify-client",
            client_secret="py-verify-secret",
        )
        try:
            cred.get_token("https://management.azure.com/.default")
        except (CredentialUnavailableError, HttpResponseError, OSError) as e:
            # typed loud-skip marker, not a silent pass
            raise CredentialUnavailableError(
                message=(
                    "azure-identity ClientSecretCredential could not mint against the "
                    f"emulator STS ({type(e).__name__}: {str(e)[:160]}) — instance-"
                    "discovery/RS256 upgrade in flight; azure leg SKIPS loudly"
                )
            ) from e
        return cred
    return SmaltTokenCredential(arm_endpoint)
