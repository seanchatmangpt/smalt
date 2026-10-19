#!/usr/bin/env python3
"""PY lane: Azure App Configuration /kv REST probes against the smalt substrate.

Venv: test/sdk-python/.venv-arm (requests; azure-appconfiguration is NOT
installed — the REST surface is probed directly, matching the
azure-appconfiguration SDK's wire format
`PUT/GET/DELETE /kv/:key?label=`). Receipt:
docs/jira/v26.10.16/sdk-results/py-appconfig.md.

Wire contract under test (lib/smalt/egress_router.ex:924-1054): PUT create
201 / CAS overwrite 200; stale If-Match -> 412; headerless overwrite of an
existing kv -> 409 WriteConflict; If-None-Match:* on existing -> 412; DELETE
REQUIRES If-Match (missing -> 409 MissingIfMatch, stale -> 412, `*` or exact
etag -> 204); post-delete GET/DELETE -> 404 KvNotFound.

Auth: enforce mode — mint a bearer from smalt's own STS
(POST /{tenant}/oauth2/v2.0/token, client_credentials), the
py_arm_resources.py convention. Tokenless /kv -> 401 via kv_challenge_guard.

Exit contract: 0 pass / 1 fail / 2 substrate down / 3 harness error.
"""
import json
import os
import socket
import sys
import time

import requests

BASE = os.environ.get("SMALT_PY_KV_ENDPOINT", "http://127.0.0.1:8443")
ARM = os.environ.get("SMALT_PY_KV_ARM", "http://127.0.0.1:9443")
TENANT = "00000000-0000-0000-0000-000000000000"

results = []
failures = [0]


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print(("[PASS] " if cond else "[FAIL] ") + name, end="")
    if detail:
        print(" :: " + detail)
    else:
        print()
    if not cond:
        failures[0] += 1


def preflight():
    """Attach, don't boot: TCP probe the egress port. Exit 2 loud, never a
    fake 1 = test fail on a dead plane."""
    port = int(BASE.rsplit(":", 1)[1])
    s = socket.socket()
    s.settimeout(2)
    try:
        s.connect(("127.0.0.1", port))
    except OSError:
        print("[appconfig-py] substrate down: no listener on 127.0.0.1:%d. Exit 2." % port)
        sys.exit(2)
    finally:
        s.close()


def mint_token():
    r = requests.post(
        f"{ARM}/{TENANT}/oauth2/v2.0/token",
        data={
            "grant_type": "client_credentials",
            "client_id": "py-appconfig",
            "client_secret": "py-appconfig",
            "scope": "https://smalt.config/.default",
        },
        timeout=10,
    )
    r.raise_for_status()
    return r.json()["access_token"]


RUN = int(time.time())
K = lambda n: f"pyprobe-{RUN}-{n}"  # noqa: E731


def main():
    preflight()
    try:
        token = mint_token()
    except Exception as e:  # harness error, not a test failure
        print(f"[appconfig-py] harness error minting STS token: {type(e).__name__}: {e}")
        return 3
    auth = {"authorization": f"Bearer {token}"}

    # 0. tokenless first touch -> 401 challenge (kv_challenge_guard over /kv)
    r0 = requests.get(f"{BASE}/kv/{K('auth')}", timeout=10)
    check("auth tokenless GET /kv -> 401 challenge", r0.status_code == 401,
          f"status={r0.status_code}")

    # 1. PUT create -> 201 with quoted etag
    key1 = K("k1")
    r1 = requests.put(f"{BASE}/kv/{key1}", params={"label": "probe"},
                      json={"value": "v1", "contentType": "text/plain"},
                      headers=auth, timeout=10)
    ok = r1.status_code == 201 and r1.json().get("etag", "").startswith('"') \
        and r1.json().get("key") == key1 and r1.json().get("value") == "v1"
    check("PUT create -> 201, quoted etag, payload round-trips", ok,
          f"status={r1.status_code} body={r1.text[:200]}")
    if not ok:
        return 1
    etag1 = r1.json()["etag"]

    # 2. GET 200 + etag header round-trip
    g1 = requests.get(f"{BASE}/kv/{key1}", params={"label": "probe"},
                      headers=auth, timeout=10)
    check("GET -> 200, value round-trips, etag header == PUT etag",
          g1.status_code == 200 and g1.json().get("value") == "v1"
          and g1.headers.get("etag") == etag1,
          f"status={g1.status_code} etag={g1.headers.get('etag')}")

    # 3. list with key= prefix filter and label= filter
    requests.put(f"{BASE}/kv/{K('k2')}", params={"label": "probe"},
                 json={"value": "v2"}, headers=auth, timeout=10)
    requests.put(f"{BASE}/kv/{K('k3')}", params={"label": "other"},
                 json={"value": "v3"}, headers=auth, timeout=10)
    l1 = requests.get(f"{BASE}/kv", params={"key": f"pyprobe-{RUN}"},
                      headers=auth, timeout=10)
    l2 = requests.get(f"{BASE}/kv", params={"key": f"pyprobe-{RUN}", "label": "other"},
                      headers=auth, timeout=10)
    l1keys = [i.get("key") for i in l1.json().get("items", [])]
    l2keys = [i.get("key") for i in l2.json().get("items", [])]
    check("list key= prefix filter returns run's items",
          l1.status_code == 200 and len(l1keys) >= 3
          and all(k.startswith(f"pyprobe-{RUN}") for k in l1keys),
          f"status={l1.status_code} items={json.dumps(l1keys)[:200]}")
    check("list label=other filter returns exactly one item",
          l2.status_code == 200 and l2keys == [K("k3")],
          f"status={l2.status_code} items={json.dumps(l2keys)}")
    check("list response carries sync-token header",
          bool(l1.headers.get("sync-token")), f"sync-token={l1.headers.get('sync-token')}")

    # 4. etag CAS: stale If-Match PUT -> 412
    st = requests.put(f"{BASE}/kv/{key1}", params={"label": "probe"},
                      json={"value": "stale"},
                      headers={**auth, "if-match": '"deadbeef"'}, timeout=10)
    check("stale If-Match PUT -> 412", st.status_code == 412,
          f"status={st.status_code} body={st.text[:120]}")

    # 5. CAS overwrite with fresh etag -> 200, etag rotates
    fr = requests.put(f"{BASE}/kv/{key1}", params={"label": "probe"},
                      json={"value": "v1b"},
                      headers={**auth, "if-match": etag1}, timeout=10)
    check("If-Match fresh etag overwrite -> 200, etag rotated",
          fr.status_code == 200 and fr.json().get("value") == "v1b"
          and fr.json().get("etag") != etag1,
          f"status={fr.status_code}")
    etag2 = fr.json().get("etag")

    # 6. create-only: If-None-Match:* on existing -> 412
    co = requests.put(f"{BASE}/kv/{key1}", params={"label": "probe"},
                      json={"value": "dup"},
                      headers={**auth, "if-none-match": "*"}, timeout=10)
    check("create-only If-None-Match:* on existing -> 412",
          co.status_code == 412, f"status={co.status_code}")

    # 7. bare overwrite without precondition headers -> 409 WriteConflict
    bo = requests.put(f"{BASE}/kv/{key1}", params={"label": "probe"},
                      json={"value": "bare"}, headers=auth, timeout=10)
    check("headerless overwrite of existing -> 409 WriteConflict",
          bo.status_code == 409, f"status={bo.status_code} body={bo.text[:120]}")

    # 8. DELETE without If-Match -> 409 MissingIfMatch
    d0 = requests.delete(f"{BASE}/kv/{key1}", params={"label": "probe"},
                         headers=auth, timeout=10)
    body_txt = d0.text[:200]
    check("DELETE without If-Match -> 409 MissingIfMatch",
          d0.status_code == 409 and "MissingIfMatch" in body_txt,
          f"status={d0.status_code} body={body_txt}")

    # 9. DELETE with stale If-Match -> 412
    ds = requests.delete(f"{BASE}/kv/{key1}", params={"label": "probe"},
                         headers={**auth, "if-match": '"deadbeef"'}, timeout=10)
    check("DELETE stale If-Match -> 412", ds.status_code == 412,
          f"status={ds.status_code}")

    # 10. DELETE If-Match:* -> 204
    d1 = requests.delete(f"{BASE}/kv/{key1}", params={"label": "probe"},
                         headers={**auth, "if-match": "*"}, timeout=10)
    check("DELETE If-Match:* -> 204", d1.status_code == 204,
          f"status={d1.status_code}")

    # 11. idempotent 404 after delete (GET and second DELETE)
    g2 = requests.get(f"{BASE}/kv/{key1}", params={"label": "probe"},
                      headers=auth, timeout=10)
    d2 = requests.delete(f"{BASE}/kv/{key1}", params={"label": "probe"},
                         headers={**auth, "if-match": "*"}, timeout=10)
    check("post-delete GET/DELETE -> 404 KvNotFound",
          g2.status_code == 404 and d2.status_code == 404
          and "KvNotFound" in g2.text,
          f"GET={g2.status_code} DELETE={d2.status_code}")

    # 12. PUT If-Match:* on never-created kv -> 412 (RFC 7232 existence assertion)
    sc = requests.put(f"{BASE}/kv/{K('kstar')}", params={"label": "probe"},
                      json={"value": "x"},
                      headers={**auth, "if-match": "*"}, timeout=10)
    check("PUT If-Match:* on absent kv -> 412 (RFC 7232)",
          sc.status_code == 412, f"status={sc.status_code}")

    # 13. DELETE with exact current etag -> 204
    requests.put(f"{BASE}/kv/{K('kdel')}", params={"label": "probe"},
                 json={"value": "bye"}, headers=auth, timeout=10)
    g3 = requests.get(f"{BASE}/kv/{K('kdel')}", params={"label": "probe"},
                      headers=auth, timeout=10)
    de = requests.delete(f"{BASE}/kv/{K('kdel')}", params={"label": "probe"},
                         headers={**auth, "if-match": g3.headers.get("etag")},
                         timeout=10)
    check("DELETE with exact current etag -> 204", de.status_code == 204,
          f"status={de.status_code}")

    n_pass = sum(1 for _, ok, _ in results if ok)
    print(f"\nappconfig py probe: {n_pass}/{len(results)} PASS")
    return 0 if failures[0] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
