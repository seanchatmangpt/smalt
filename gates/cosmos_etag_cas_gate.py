#!/usr/bin/env python3
"""Invariant gate: Cosmos ETag compare-and-swap — exactly one winner.

Positive: against a live substrate, create a doc, then fire N concurrent
conditional PUTs (If-Match: <etag>) at it. The CAS is serialized inside the
Store GenServer (lib/smalt/data_plane/cosmos.ex: put_doc), so exactly one
request gets 200 and the rest get 412 PreconditionFailed. Also verifies the
etag contract: quoted RFC-4122 v4 GUID (KD-148 SDK alignment; the gate
follows the SDK, never the reverse), stable across reads, refreshed on write.

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
# KD-148: quoted RFC-4122 v4 GUID — version nibble '4', variant nibble 8/9/a/b.
# KD-COVERS: KD-148 (gate-side mirror of the lib/smalt/data_plane/cosmos.ex fix)
ETAG_RE = re.compile(
    r"^\"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\"$")


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
                            # Cosmos 412 body renders `code` at TOP level
            # (lib/smalt/data_plane/cosmos.ex error_response);
            # error.code is the blob-arm shape, kept as fallback.
            "code": ((body or {}).get("code")
                     or (body or {}).get("error", {}).get("code"))
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
          "create etag is quoted RFC-4122 v4 GUID (KD-148 SDK shape)")
    check(obs.get("etag_create") == obs.get("etag_reread"),
          "etag stable across read")
    check(obs.get("race") == [200] + [412] * 5,
          f"exactly one 200 and five 412s (got {obs.get('race')})")
    codes = [c for c in obs.get("race_codes", []) if c]
    check(len(codes) == 5 and all(c == "PreconditionFailed" for c in codes),
          "losers carry PreconditionFailed with codes present (5 losers, none stripped)")
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

    def etag_unstable_reread(o):
        # SHIM-COURT-style negative fixture: mutating only etag_reread must
        # trip the stable-across-read check. (Also wrong shape: 64-hex, not GUID.)
        o = dict(o)
        o["etag_reread"] = "\"" + ("e" * 64) + "\""
        return o

    def legacy_64hex_etag(o):
        # SHIM-COURT-style negative fixture: the pre-KD-148 quoted 64-hex
        # sha256 etag shape must be REFUSED — the SDK-aligned contract is a
        # quoted GUID only.
        o = dict(o)
        o["etag_create"] = "\"" + ("a" * 64) + "\""
        o["etag_reread"] = o["etag_create"]
        return o

    def unquoted_guid(o):
        # SHIM-COURT-style negative fixture: same GUID, quotes stripped.
        o = dict(o)
        guid = obs.get("etag_create", "").strip("\"")
        o["etag_create"] = guid
        o["etag_reread"] = guid
        return o

    def all_empty_race_codes(o):
        # SHIM-COURT-style negative fixture: losers with stripped/empty codes
        # must NOT pass vacuously — codes must be present and PreconditionFailed.
        o = dict(o)
        o["race_codes"] = [""] * 6
        return o

    def bad_etag_format(o):
        o = dict(o)
        o["etag_create"] = "unquoted-not-hex"
        return o

    return [(n, f(obs)) for n, f in
            [("two-winners", two_winners), ("no-winner", no_winner),
             ("etag-not-refreshed", etag_not_refreshed),
             ("stale-write-accepted", stale_write_accepted),
             ("etag-unstable-reread", etag_unstable_reread),
             ("legacy-64hex-etag", legacy_64hex_etag),
             ("unquoted-guid", unquoted_guid),
             ("all-empty-race-codes", all_empty_race_codes),
             ("bad-etag-format", bad_etag_format)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("cosmos-etag-cas", capture, verdict, mutate_fixtures))
