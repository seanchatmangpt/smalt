#!/usr/bin/env python3
"""PY-1: real Python azure-mgmt SDK against the smalt ARM gateway.
Venv: test/sdk-python/.venv-arm (receipt: docs/jira/v26.10.14/sdk-results/py-arm-resources.md).

Probes:
  P0 discovery: GET /metadata/endpoints (raw wire)
  P1 ResourceManagementClient list subscriptions
  P2 resource group create / list / get via SDK
  P3 generic resource LRO create (storageAccounts is an smalt LRO-async type),
     wire-truth GET, SDK delete
  P4 negative: bad api-version -> 400 naming the expected version
  P5 RG delete -> 404 on get
"""
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("SMALT_ARM_BASE", "https://127.0.0.1:9444")
SUB = "00000000-0000-0000-0000-000000000000"

# dev (self-signed CN=127.0.0.1) cert: accept for the local substrate only
import ssl  # noqa: E402
TLS_CTX = ssl._create_unverified_context()

import http.client  # noqa: E402

from azure.core.credentials import AccessToken  # noqa: E402
from azure.mgmt.resource import ResourceManagementClient  # noqa: E402

RESULTS = []


def record(name, ok, detail=""):
    RESULTS.append((name, bool(ok), str(detail)))
    print(("PASS" if ok else "FAIL") + " " + name + ((" :: " + str(detail)) if detail else ""))


class SmaltTokenCredential:
    """Mints a bearer from smalt's own STS (POST /oauth2/v2.0/token,
    client_credentials) and presents it as azure-identity would: Bearer
    header with exp-based early refresh."""

    def get_token(self, *scopes, **kwargs):
        body = urllib.parse.urlencode({
            "grant_type": "client_credentials",
            "client_id": "py-sdk",
            "client_secret": "py-sdk",
            "scope": "https://management.azure.com/.default",
        }).encode()
        req = urllib.request.Request(
            BASE + "/oauth2/v2.0/token",
            data=body,
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
        with urllib.request.urlopen(req, timeout=15, context=TLS_CTX) as resp:
            tok = json.load(io.TextIOWrapper(resp, "utf-8"))
        exp = int(time.time()) + int(tok["expires_in"])
        return AccessToken(tok["access_token"], exp - 300)


def raw(method, path, body=None, headers=None):
    """Raw wire request (bypasses the SDK) for wire-truth assertions."""
    h = {"content-type": "application/json"}
    if headers:
        h.update(headers)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15, context=TLS_CTX) as r:
            payload = r.read().decode()
            return r.status, (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as e:
        payload = e.read().decode()
        try:
            return e.code, json.loads(payload)
        except ValueError:
            return e.code, payload


def main():
    cred = SmaltTokenCredential()
    token = cred.get_token()
    auth = {"authorization": "Bearer " + token.token}

    # P0: discovery
    st, meta = raw("GET", "/metadata/endpoints")
    record("P0 metadata/endpoints 200", st == 200, "status=" + str(st))
    record(
        "P0b resourceManagerEndpoint present",
        st == 200 and isinstance(meta, dict) and meta.get("resourceManagerEndpoint") is not None,
        str(meta.get("resourceManagerEndpoint") if isinstance(meta, dict) else meta)[:120],
    )

    client = ResourceManagementClient(
        cred, SUB, base_url=BASE, api_version="2021-04-01", polling_interval=0.5,
        connection_verify=False,
    )

    # P1: list subscriptions via SDK (SubscriptionClient, as the real SDK splits)
    from azure.mgmt.resource.subscriptions import SubscriptionClient
    sub_client = SubscriptionClient(cred, base_url=BASE, connection_verify=False)
    subs = list(sub_client.subscriptions.list())
    record("P1 SDK list subscriptions >=1", len(subs) >= 1,
           "count=" + str(len(subs)) + " first=" + str(getattr(subs[0], "subscription_id", None)))

    # P2: RG create / list / get
    rg = "py-sdk-rg"
    rg_obj = client.resource_groups.create_or_update(rg, {"location": "smaltlocal"})
    record("P2a RG create", rg_obj.name == rg, "name=" + str(rg_obj.name) + " loc=" + str(rg_obj.location))

    rgs = list(client.resource_groups.list())
    record("P2b RG list contains rg", any(r.name == rg for r in rgs), "count=" + str(len(rgs)))
    got = client.resource_groups.get(rg)
    record("P2c RG get", got.name == rg, "name=" + str(got.name))

    # P3: generic resource create via LRO (smalt LRO-async type: storageAccounts)
    # NOTE: begin_create_or_update with parent_resource_path="" emits a
    # double-slash URL (`providers/Microsoft.Storage//storageAccounts/...`)
    # which smalt 404s (RouteNotFound); real ARM tolerates it. Divergence
    # recorded; using the by-path variant with the exact resource id instead.
    sa_id = ("/subscriptions/" + SUB + "/resourceGroups/" + rg
             + "/providers/Microsoft.Storage/storageAccounts/pysa001")
    sa_poller = client.resources.begin_create_or_update_by_id(
        sa_id, "2021-04-01",
        {"location": "smaltlocal",
         "sku": {"name": "Standard_LRS", "tier": "Standard"},
         "kind": "StorageV2",
         "properties": {"skuName": "Standard_LRS",
                        "supportsHttpsTrafficOnly": True}},
    )
    sa = sa_poller.result()
    ok = sa.name == "pysa001"
    record("P3 LRO storageAccount create", ok,
           "name=" + str(sa.name) + " state=" + str(getattr(sa, "provisioning_state", None)))

    st, body = raw(
        "GET",
        "/subscriptions/" + SUB + "/resourceGroups/" + rg
        + "/providers/Microsoft.Storage/storageAccounts/pysa001?api-version=2021-04-01",
        headers=auth,
    )
    record("P3b wire GET storageAccount 200", st == 200, "status=" + str(st))

    try:
        client.resources.begin_delete_by_id(sa_id, "2021-04-01").result()
        record("P3c storageAccount delete", True, "poller succeeded")
    except Exception as e:  # noqa: BLE001
        record("P3c storageAccount delete", False, repr(e))

    # P4: negative — bad api-version -> 400 naming expected version
    st, body = raw(
        "GET",
        "/subscriptions/" + SUB + "/resourceGroups?api-version=1999-01-01",
        headers=auth,
    )
    msg = json.dumps(body)
    record("P4 bad api-version -> 400", st == 400, "status=" + str(st))
    record("P4b error names 2021-04-01", "2021-04-01" in msg, msg[:200])

    # P5: cleanup + RG delete proof
    client.resource_groups.begin_delete(rg).result()
    st, _ = raw("GET",
                "/subscriptions/" + SUB + "/resourceGroups/" + rg + "?api-version=2021-04-01",
                headers=auth)
    record("P5 RG delete -> 404", st == 404, "status=" + str(st))

    print()
    failed = [r for r in RESULTS if not r[1]]
    print("=== " + str(len(RESULTS) - len(failed)) + "/" + str(len(RESULTS)) + " probes passed ===")
    if failed:
        print("FAILURES:")
        for n, _ok, d in failed:
            print("  - " + n + ": " + d)
        sys.exit(1)


if __name__ == "__main__":
    main()
