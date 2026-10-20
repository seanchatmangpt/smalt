#!/usr/bin/env python3
"""examples/python_client.py — stdlib-only smalt client walk.

Against a running substrate (default loopback 9443/8443, override with
SMALT_ARM / SMALT_EGRESS):
  1. GET /metadata/endpoints (discovery doc)
  2. STS token mint (POST /oauth2/v2.0/token, client_credentials)
  3. ARM resource-group create / list / delete with the minted bearer
  4. Blob put / get round-trip on the egress router (8443)

No substrate management here — boot one first, e.g.:
    scripts/substrate-ctl up --block examples --auth anonymous
Exits 0 green, 1 on the first wire failure.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

ARM = os.environ.get("SMALT_ARM", "http://127.0.0.1:9443").rstrip("/")
EGRESS = os.environ.get("SMALT_EGRESS", "http://127.0.0.1:8443").rstrip("/")


def req(method, url, data=None, headers=None):
    body = data.encode() if isinstance(data, str) else data
    r = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return resp.read().decode()


def req_json(method, url, data=None, headers=None):
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    return json.loads(req(method, url, data, h))


def main():
    suffix = "?api-version=2022-09-01"

    # 1. Discovery doc.
    md = req_json("GET", f"{ARM}/metadata/endpoints")
    assert "resourceManager" in md, f"metadata doc: {md!r}"
    print(f"ok: metadata doc — resourceManager={md['resourceManager']}")

    # 2. STS mint.
    form = "grant_type=client_credentials&client_id=py-example&client_secret=x"
    tok = json.loads(req("POST", f"{ARM}/oauth2/v2.0/token", form,
                         {"Content-Type": "application/x-www-form-urlencoded"}))["access_token"]
    print(f"ok: STS token minted (len={len(tok)})")
    bearer = {"Authorization": f"Bearer {tok}"}

    # 3. Resource-group lifecycle (bearer-authed).
    sub = "00000000-0000-0000-0000-000000000000"
    rg = f"py-example-rg-{int(time.time())}"
    rg_url = f"{ARM}/subscriptions/{sub}/resourcegroups/{rg}{suffix}"
    out = req_json("PUT", rg_url, json.dumps({"location": "westus2"}), bearer)
    assert out.get("properties", {}).get("provisioningState") == "Succeeded", f"rg create: {out!r}"
    print(f"ok: rg create — {rg}")
    lst = req_json("GET", f"{ARM}/subscriptions/{sub}/resourcegroups{suffix}", None, bearer)
    assert rg in str(lst), "created rg missing from list"
    print("ok: rg appears in list")
    req("DELETE", rg_url, None, bearer)
    try:
        tail = req("GET", rg_url, None, bearer)
    except urllib.error.HTTPError as e:
        tail = {} if e.code == 404 else None
        if tail is None:
            raise
    assert "provisioningState" not in tail, f"rg still present after delete: {tail!r}"
    print("ok: rg deleted + gone")

    # 4. Blob round-trip via the egress router.
    acct = f"pyacct{int(time.time())}"
    blob_url = f"{EGRESS}/{acct}/examples/example-blob"
    payload = f"python client blob at {time.time()}"
    v = {"x-ms-version": "2020-07-07"}
    req("PUT", f"{EGRESS}/{acct}/examples?restype=container", headers=v)
    req("PUT", blob_url, data=payload, headers={"x-ms-blob-type": "BlockBlob", **v})
    got = req("GET", blob_url, headers=v)
    assert got == payload, f"blob mismatch: {got!r}"
    print("ok: blob round-trip")

    print("GREEN: python_client.py passed all steps")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 — examples surface raw failure loudly
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
