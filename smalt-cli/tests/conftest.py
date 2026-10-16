"""CLI-4 SDK test lanes (Gate 1, part A): shared substrate fixture.

Endpoint/auth shapes mirror the repo's real-SDK probes:
  - test/sdk-python/py_arm_resources.py   (STS client_credentials over the ARM
    gateway, Bearer for management plane)
  - test/sdk-python/py_cosmos.py          (Cosmos master-key signing, any
    64-hex key in MIX_ENV=test anonymous mode)
  - test/sdk-python/py_storage_blob.py    (SharedKey conn string, account
    smaltacct, any non-empty key)

Env: SMALT_ARM / SMALT_EGRESS override the defaults
(http://127.0.0.1:39643 / http://127.0.0.1:39644 — this lane's private
substrate, docs/DEV_LOOP.md private range 39000-39999).

NO SUBSTRATE, NO PASS: if neither the env-configured nor the default
substrate answers /metadata/endpoints, every test SKIPs with a loud banner
naming the boot command — a missing substrate is never faked into a pass.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

import pytest

ARM = os.environ.get("SMALT_ARM", "http://127.0.0.1:39643")
EGRESS = os.environ.get("SMALT_EGRESS", "http://127.0.0.1:39644")
AUD = "https://management.azure.com"
SUB = "sub-cli4"
TLS_CTX = ssl._create_unverified_context()

BOOT_HINT = (
    "SMALT SUBSTRATE UNREACHABLE at ARM=%s EGRESS=%s — SKIP-PENDING. "
    "Boot one with: cd /Users/sac/smalt && flock -x /tmp/smalt-substrate.lock "
    "MIX_ENV=test mix run --no-start --no-halt -e "
    "'Application.put_env(:smalt, :arm_port, <arm_port>); "
    "Application.put_env(:smalt, :egress_port, <egress_port>); "
    "Application.put_env(:smalt, :arm_tls_port, <arm_tls>); "
    "{:ok, _} = Application.ensure_all_started(:smalt)' "
    "(see docs/DEV_LOOP.md and test/sdk-python/run.sh)" % (ARM, EGRESS)
)


def http(method, url, body=None, headers=None, timeout=15):
    """Raw JSON wire request. Returns (status, parsed-or-raw-body)."""
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=TLS_CTX) as r:
            payload = r.read().decode()
            return r.status, (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def sts_token(tenant="cli4-tenant"):
    """client_credentials grant against the smalt STS -> (access_token, claims)."""
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": "cli4-lane",
        "client_secret": "cli4-secret",
    }).encode()
    req = urllib.request.Request(
        f"{ARM}/oauth2/v2.0/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=15, context=TLS_CTX) as resp:
        tok = json.loads(resp.read())
    token = tok["access_token"]
    payload_b64 = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload_b64 + "=" * (-len(payload_b64) % 4)))
    return token, claims


def bearer():
    token, _ = sts_token()
    return {"Authorization": f"Bearer {token}"}


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_jwt(claims, secret=b"py-lane6-known-secret-0123456789abcdef"):
    header = b64u(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = b64u(json.dumps(claims).encode())
    signing_input = f"{header}.{payload}".encode()
    sig = hmac.new(secret, signing_input, hashlib.sha256).digest()
    return f"{header}.{payload}.{b64u(sig)}"


def blob_conn_string():
    key = base64.b64encode(b"smaltacct-key").decode()
    return (
        f"DefaultEndpointsProtocol=http;AccountName=smaltacct;"
        f"AccountKey={key};BlobEndpoint={EGRESS}/smaltacct;"
    )


def cosmos_client():
    import azure.cosmos.cosmos_client as cc

    return cc.CosmosClient(EGRESS, credential=secrets.token_hex(32))


def _substrate_reachable():
    try:
        st, _ = http("GET", f"{ARM}/metadata/endpoints", timeout=5)
        return st == 200
    except Exception:
        return False


@pytest.fixture(scope="session", autouse=True)
def substrate():
    if not _substrate_reachable():
        print("\n" + "#" * 72)
        print(BOOT_HINT)
        print("#" * 72, flush=True)
        pytest.skip(BOOT_HINT)
    return {"arm": ARM, "egress": EGRESS, "aud": AUD, "sub": SUB}


def seed_resource(name, rg="cli4-rg", location="eastus"):
    st, body = http(
        "PUT",
        f"{ARM}/subscriptions/{SUB}/resourceGroups/{rg}/providers/"
        f"Microsoft.Storage/storageAccounts/{name}?api-version=2021-04-01",
        {"location": location, "properties": {"skuName": "Standard_LRS"}},
        bearer(),
    )
    assert st in (200, 201, 202), f"seed PUT {name} -> {st}: {body}"
    return st


@pytest.fixture(scope="session")
def seeded_resources():
    """Five storage accounts under one RG for resourcegraph pagination."""
    http("PUT", f"{ARM}/subscriptions/{SUB}/resourceGroups/cli4-rg?api-version=2021-04-01",
         {"location": "eastus"}, bearer())
    names = [f"cli4sa{i}" for i in range(1, 6)]
    for n in names:
        seed_resource(n)
    return names
