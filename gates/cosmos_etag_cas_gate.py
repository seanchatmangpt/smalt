#!/usr/bin/env python3
"""Invariant gate: Cosmos ETag compare-and-swap — exactly one winner.

Positive: against a live substrate, create a doc, then fire N concurrent
conditional PUTs (If-Match: <etag>) at it. The CAS is serialized inside the
Store GenServer (lib/smalt/data_plane/cosmos.ex: put_doc), so exactly one
request gets 200 and the rest get 412 PreconditionFailed. Also verifies the
etag contract: quoted 64-hex, stable across reads, refreshed on write.

Negative fixtures (pack harness shape): mutated copies of the captured
observations — two 200s (lost update), zero 200s, missing 412s, stale etag
reused, bad etag format — each MUST be refused by the same verdict function,
proving the gate is non-vacuous.

Usage: python3 gates/cosmos_etag_cas_gate.py   (exit 0 = hold, 1 = violated)
"""
import json
import os
import re
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

DB, COLL, DOC = "gatedb", "gatecoll", "gatedoc"
ETAG_RE = re.compile(r"^\"[0-9a-f]{64}\"$")


def capture(ports, shared_key):
    egress = ports["egress"]
    base = f"/dbs/{DB}/colls/{COLL}/docs"
    s, _, doc = common.http(egress, "POST", base,
                            {"id": DOC, "pk": "gate", "v": 1})
    assert s == 201, f"doc create returned {s}: {doc}"
    etag1 = doc["_etag"]
    s, _, reread = common.http(egress, "GET", f"{base}/{DOC}")
    assert s == 200, f"doc read returned {s}"
    etag2 = reread["_etag"]

    # N concurrent conditional writes from the SAME etag: exactly one 200.
    results = []
    lock = threading.Lock()

    def worker(i):
        st, _, body = common.http(
            egress, "PUT", f"{base}/{DOC}", {"v": 2, "worker": i},
            headers={"If-Match": etag1})
        with lock:
            results.append({"worker": i, "status": st,
                            "code": (body or {}).get("error", {}).get("code")
                            if isinstance(body, dict) else None})

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    s, _, newdoc = common.http(egress, "GET", f"{base}/{DOC}")
    final_etag = newdoc.get("_etag") if isinstance(newdoc, dict) else None

    # A stale-etag write after the race must refuse.
    stale_status, _, _ = common.http(egress, "PUT", f"{base}/{DOC}",
                                     {"v": 3}, headers={"If-Match": etag1})

    return {
        "create_status": s,  # last GET status
        "etag_create": etag1,
        "etag_reread": etag2,
        "race": sorted(r["status"] for r in results),
        "race_codes": sorted(r["code"] or "" for r in results),
        "final_etag": final_etag,
        "stale_write_status": stale_status,
    }


def verdict(obs):
    details = []
    ok = True

    def check(cond, msg):
        nonlocal ok
        details.append(("PASS" if cond else "FAIL") + " " + msg)
        ok = ok and cond

    check(ETAG_RE.match(obs.get("etag_create", "")) is not None,
          "create etag is quoted 64-hex")
    check(obs.get("etag_create") == obs.get("etag_reread"),
          "etag stable across read")
    check(obs.get("race") == [200] + [412] * 5,
          f"exactly one 200 and five 412s (got {obs.get('race')})")
    codes = [c for c in obs.get("race_codes", []) if c]
    check(all(c == "PreconditionFailed" for c in codes),
          "losers carry PreconditionFailed")
    check(obs.get("final_etag") not in (None, obs.get("etag_create")),
          "etag refreshed on write")
    check(obs.get("stale_write_status") == 412,
          "stale etag reused -> 412")
    return ok, details


def mutate_fixtures(obs):
    def two_winners(o):
        o = dict(o)
        o["race"] = [200, 200, 412, 412, 412, 412]
        return o

    def no_winner(o):
        o = dict(o)
        o["race"] = [412] * 6
        return o

    def etag_not_refreshed(o):
        o = dict(o)
        o["final_etag"] = o["etag_create"]
        return o

    def stale_write_accepted(o):
        o = dict(o)
        o["stale_write_status"] = 200
        return o

    def bad_etag_format(o):
        o = dict(o)
        o["etag_create"] = "unquoted-not-hex"
        return o

    return [(n, f(obs)) for n, f in
            [("two-winners", two_winners), ("no-winner", no_winner),
             ("etag-not-refreshed", etag_not_refreshed),
             ("stale-write-accepted", stale_write_accepted),
             ("bad-etag-format", bad_etag_format)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("cosmos-etag-cas", capture, verdict, mutate_fixtures))
