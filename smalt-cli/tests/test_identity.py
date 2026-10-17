"""CLI-4 identity lane: smalt STS client_credentials -> token claims; tampered -> 401.

Mirrors test/sdk-python/py_auth_keyvault.py (SmaltTokenCredential) and
py_resourcegraph_monitor.py (StsCredential).
"""
import base64
import json
import time

import pytest
import requests

import conftest
from conftest import AUD, http, mint_jwt, sts_token

# Identity needs auth_mode=:enforce (401 challenges) — exclusive of the
# anonymous substrate that blob/cosmos use (X-6 session split).
pytestmark = [pytest.mark.enforce, pytest.mark.usefixtures("enforce_substrate")]


def _b64u_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def test_client_credentials_mint_and_claims():
    token, claims = sts_token()
    assert isinstance(token, str) and token.count(".") == 2
    assert claims["aud"] == AUD, claims
    assert claims["exp"] > time.time(), claims
    assert claims["iat"] <= time.time() + 60, claims
    assert claims["iss"], claims


def test_valid_bearer_200_subscriptions():
    token, _ = sts_token()
    r = requests.get(f"{conftest.ARM}/subscriptions?api-version=2021-04-01",
                     headers={"Authorization": f"Bearer {token}"}, timeout=10)
    assert r.status_code == 200, r.text[:200]


def test_tokenless_401_challenge():
    r = requests.get(f"{conftest.ARM}/subscriptions?api-version=2021-04-01", timeout=10)
    assert r.status_code == 401
    assert r.headers.get("WWW-Authenticate", "").startswith("Bearer"), dict(r.headers)


def test_tampered_signature_401():
    token, _ = sts_token()
    h, p, s = token.split(".")
    flipped = bytearray(s.encode())
    flipped[0] ^= 1
    r = requests.get(
        f"{conftest.ARM}/subscriptions?api-version=2021-04-01",
        headers={"Authorization": "Bearer " + ".".join([h, p, base64.urlsafe_b64encode(bytes(flipped)).rstrip(b"=").decode()])},
        timeout=10,
    )
    body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    assert r.status_code == 401, r.status_code
    assert body.get("error", {}).get("message") == "SignatureVerificationFailed", body


def test_self_minted_wrong_secret_401():
    now = int(time.time())
    forged = mint_jwt({
        "aud": AUD,
        "iss": f"{conftest.ARM}/00000000-0000-0000-0000-000000000000/v2.0",
        "iat": now,
        "nbf": now,
        "exp": now + 3600,
    }, secret=b"wrong-secret-wrong-secret-wrong-secret")
    st, body = http("GET", f"{conftest.ARM}/subscriptions?api-version=2021-04-01",
                    headers={"Authorization": f"Bearer {forged}"})
    assert st == 401, (st, body)
    assert body["error"]["message"] == "SignatureVerificationFailed", body


def test_expired_self_minted_401():
    now = int(time.time())
    expired = mint_jwt({"aud": AUD,
                        "iss": f"{conftest.ARM}/00000000-0000-0000-0000-000000000000/v2.0",
                        "issuedAt": now - 7200,
                        "iat": now - 7200,
                        "nbf": now - 7200,
                        "exp": now - 3600})
    st, body = http("GET", f"{conftest.ARM}/subscriptions?api-version=2021-04-01",
                    headers={"Authorization": f"Bearer {expired}"})
    assert st == 401, (st, body)
    assert body["error"]["message"] == "TokenExpired", body


# Bearer sub-code pins (ERROR_CODES.md "Bearer sub-codes" section, 2026-10-17):
# each self-minted token exercises one {:refuse, parent, sub} branch in
# lib/smalt/auth/bearer.ex and the sub-code rides the 401 envelope's message.

def test_not_yet_valid_self_minted_401():
    now = int(time.time())
    early = mint_jwt({"aud": AUD,
                      "iss": f"{conftest.ARM}/00000000-0000-0000-0000-000000000000/v2.0",
                      "iat": now,
                      "nbf": now + 3600,
                      "exp": now + 7200})
    st, body = http("GET", f"{conftest.ARM}/subscriptions?api-version=2021-04-01",
                    headers={"Authorization": f"Bearer {early}"})
    assert st == 401, (st, body)
    assert body["error"]["message"] == "TokenNotYetValid", body


def test_wrong_audience_401():
    now = int(time.time())
    foreign = mint_jwt({"aud": "https://other-surface.example.com",
                        "iss": f"{conftest.ARM}/00000000-0000-0000-0000-000000000000/v2.0",
                        "iat": now,
                        "nbf": now,
                        "exp": now + 3600})
    st, body = http("GET", f"{conftest.ARM}/subscriptions?api-version=2021-04-01",
                    headers={"Authorization": f"Bearer {foreign}"})
    assert st == 401, (st, body)
    assert body["error"]["message"] == "AudienceMismatch", body


def test_wrong_issuer_401():
    now = int(time.time())
    foreign = mint_jwt({"aud": AUD,
                        "iss": "https://evil.example.com/00000000-0000-0000-0000-000000000000/v2.0",
                        "iat": now,
                        "nbf": now,
                        "exp": now + 3600})
    st, body = http("GET", f"{conftest.ARM}/subscriptions?api-version=2021-04-01",
                    headers={"Authorization": f"Bearer {foreign}"})
    assert st == 401, (st, body)
    assert body["error"]["message"] == "IssuerMismatch", body
