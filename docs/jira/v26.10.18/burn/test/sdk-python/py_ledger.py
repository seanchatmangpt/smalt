#!/usr/bin/env python3
"""PY lane (KD-43): Confidential Ledger REST probes against the smalt substrate.

Venv: test/sdk-python/.venv-arm (requests; azure-confidentialledger is NOT
installed — the REST surface is probed directly, matching the
azure-confidentialledger SDK's wire format
`POST/GET /app/transactions`). Receipt:
docs/jira/v26.10.16/sdk-results/py-ledger.md.

Scope (coordinator trim, 80/20): append/read happy path + lazy-create append
(never-created subledger -> success, matching real-service semantics where
appending materializes the subledger). Registered divergences stay KD rows.

Endpoint: http://127.0.0.1:<EGRESS_PORT> (MIX_ENV=test, anonymous auth).
"""
import json
import os
import secrets
import sys
import urllib.parse

import requests

EGRESS_PORT = os.environ.get("EGRESS_PORT", "39328")
BASE = "http://127.0.0.1:" + EGRESS_PORT

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print(("[PASS] " if cond else "[FAIL] ") + name, end="")
    if detail:
        print(" :: " + detail)
    else:
        print()


def main():
    tag = secrets.token_hex(4)

    # 1. Lazy-create append: POST to a never-created ledger/subledger succeeds.
    # Real Confidential Ledger semantics: an append to a fresh subledger
    # materializes it with transaction id 1.1 (2.100-ish in real service; the
    # "<seq>.1" form is the emulator convention). Divergence vs the real
    # service's 404-on-unknown-ledger is covered by the lib/ existence fence,
    # not here — this probe pins the emulator's lazy-create contract.
    payload = {"contents": {"msg": "py-ledger-" + tag, "n": 1}}
    r = requests.post(BASE + "/app/transactions", json=payload, timeout=10)
    ok = r.status_code == 201
    check("append lazy-create subledger (POST /app/transactions -> 201)", ok,
          "status=" + str(r.status_code) + " body=" + r.text[:200])
    if not ok:
        return 1
    receipt = r.json()
    tx_id = receipt.get("transactionId", "")
    check("append receipt has transactionId", bool(tx_id), "transactionId=" + tx_id)
    # Divergence (filed in py-ledger.md): the emulator wraps the posted body's
    # contents one level deeper than the real service — wire receipt carries
    # {"contents": {"contents": <payload>}} where azure-confidentialledger
    # surfaces <payload> directly at receipt["contents"]. Pinned here as the
    # emulator's documented convention; inner payload must still round-trip.
    check("append receipt echoes contents (wrapped shape, see receipt)",
          isinstance(receipt.get("contents"), dict)
          and receipt["contents"].get("contents") == payload["contents"],
          json.dumps(receipt.get("contents"))[:120])
    check("append receipt has signature + merkle chain fields",
          all(k in receipt for k in
              ("signature", "merkle_root", "prev_hash", "data_hash")))

    # 2. Read back by tx id.
    r = requests.get(BASE + "/app/transactions/" + urllib.parse.quote(tx_id),
                     timeout=10)
    got = r.json() if r.status_code == 200 else {}
    check("read by transactionId (GET /app/transactions/:txId -> 200)",
          r.status_code == 200 and got.get("transactionId") == tx_id,
          "status=" + str(r.status_code))

    # 3. Read latest.
    r = requests.get(BASE + "/app/transactions/latest", timeout=10)
    got = r.json() if r.status_code == 200 else {}
    check("read latest (GET /app/transactions/latest -> 200)",
          r.status_code == 200 and got.get("transactionId") == tx_id,
          "status=" + str(r.status_code))

    # 4. Second append advances the monotonic seq; list shows both.
    payload2 = {"contents": {"msg": "py-ledger-" + tag + "-2", "n": 2}}
    r = requests.post(BASE + "/app/transactions", json=payload2, timeout=10)
    ok2 = r.status_code == 201
    tx2 = r.json().get("transactionId", "") if ok2 else ""
    check("second append -> 201 with new transactionId",
          ok2 and tx2 and tx2 != tx_id,
          "tx1=" + tx_id + " tx2=" + tx2)

    r = requests.get(BASE + "/app/transactions", timeout=10)
    ids = [t.get("transactionId") for t in r.json()] if r.status_code == 200 else []
    check("list transactions contains both appends in order",
          r.status_code == 200 and ids == [tx_id, tx2],
          "status=" + str(r.status_code) + " ids=" + str(ids))

    failed = [n for (n, ok, _) in results if not ok]
    total = len(results)
    print("\n[py-ledger] %d/%d checks PASS" % (total - len(failed), total))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
