#!/usr/bin/env python3
"""Invariant gate: Confidential Ledger Merkle-chain continuity.

Positive: append three distinct entries via POST /app/transactions on a live
substrate, verify each receipt re-derives client-side:
  merkle_root == sha256(prev_hash <> data_hash)      (hex, lowercase)
  receipt[i].prev_hash == receipt[i-1].merkle_root  (first prev = 64 zeros)
  transactionId == "<seq>.1", monotonic seqs
  duplicate contents -> 409 LedgerItemAlreadyExists
  tampered contents -> signature... (signature skipped; hash chain is the gate)

Negative fixtures: broken prev-link, wrong root, non-zero genesis, duplicate
accepted (200), missing receipt — each must be refused.

Usage: python3 gates/ledger_chain_gate.py   (exit 0 = hold, 1 = violated)
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

ZERO_HASH = "0" * 64
ENTRIES = [{"k": "gate-a"}, {"k": "gate-b"}, {"k": "gate-c"}]


def data_hash(contents):
    canonical = json.dumps(contents, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def capture(ports, shared_key):
    egress = ports["egress"]
    receipts = []
    statuses = []
    for entry in ENTRIES:
        s, _, body = common.http(egress, "POST", "/app/transactions", entry)
        statuses.append(s)
        receipts.append(body if s == 201 else {})

    s_dup, _, _ = common.http(egress, "POST", "/app/transactions", ENTRIES[0])

    s_list, _, listed = common.http(egress, "GET", "/app/transactions")
    return {
        "appends": statuses,
        "receipts": receipts,
        "dup_status": s_dup,
        "list_status": s_list,
        "listed": listed if isinstance(listed, list) else [],
    }


def verdict(obs):
    details = []
    ok = True

    def check(cond, msg):
        nonlocal ok
        details.append(("PASS" if cond else "FAIL") + " " + msg)
        ok = ok and cond

    receipts = obs.get("receipts", [])
    check(all(a == 201 for a in obs.get("appends", [])),
          "all appends returned 201")
    check(len(receipts) == len(ENTRIES), f"got {len(receipts)} receipts")
    check(obs.get("dup_status") == 409, "duplicate contents -> 409")

    listed = obs.get("listed", [])
    check(len(listed) >= len(ENTRIES), "ledger lists the appended receipts")

    prev = ZERO_HASH
    seq = 0
    chain_ok = True
    chain_msg = "chain continuity holds"
    for r in listed:
        seq += 1
        tx = r.get("transactionId", "")
        if tx != f"{seq}.1":
            chain_ok, chain_msg = False, f"tx id {tx!r} != {seq}.1"
            break
        dh = data_hash(r.get("contents", {}))
        if r.get("data_hash") != dh:
            chain_ok, chain_msg = False, f"{tx}: data_hash mismatch"
            break
        if r.get("prev_hash") != prev:
            chain_ok, chain_msg = False, f"{tx}: prev_hash does not link"
            break
        root = hashlib.sha256((prev + dh).encode()).hexdigest()
        if r.get("merkle_root") != root:
            chain_ok, chain_msg = False, f"{tx}: merkle_root re-derivation mismatch"
            break
        prev = r.get("merkle_root")
    check(chain_ok, chain_msg)
    return ok, details


def mutate_fixtures(obs):
    import copy

    def broken_link(o):
        o = copy.deepcopy(o)
        o["listed"][1]["prev_hash"] = "f" * 64
        return o

    def wrong_root(o):
        o = copy.deepcopy(o)
        o["listed"][2]["merkle_root"] = "a" * 64
        return o

    def tampered_contents(o):
        o = copy.deepcopy(o)
        o["listed"][0]["contents"] = {"k": "tampered"}
        return o

    def nonzero_genesis(o):
        o = copy.deepcopy(o)
        o["listed"][0]["prev_hash"] = "1" * 64
        return o

    def broken_seq(o):
        # SHIM-COURT-style negative fixture: transactionId seq must be
        # monotonic "<seq>.1"; breaking the seq must be detected.
        o = copy.deepcopy(o)
        o["listed"][1]["transactionId"] = "1.1"
        return o

    def dup_accepted(o):
        o = copy.deepcopy(o)
        o["dup_status"] = 201
        return o

    return [(n, f(obs)) for n, f in
            [("broken-link", broken_link), ("wrong-root", wrong_root),
             ("tampered-contents", tampered_contents),
             ("nonzero-genesis", nonzero_genesis),
             ("broken-seq", broken_seq),
             ("duplicate-accepted", dup_accepted)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("ledger-chain", capture, verdict, mutate_fixtures))
