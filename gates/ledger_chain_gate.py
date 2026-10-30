#!/usr/bin/env python3
"""Invariant gate: Confidential Ledger Merkle-chain continuity (core).

WO-22/23/24 gate retarget (v26.10.31 inversion, 2026-10-30). The ledger-chain
invariant STAYS CORE per the L8 ruling (sha256 Merkle chain; the BLAKE3
turnstile-digest retarget is PENDING THE CORE SWAP -- recorded here, not
wired, because the serving face still folds sha256(prev <> data_hash)).

The gate's subject moved twice under it:

  1. Real-Azure no-dedupe law (2026-10-25, per the ConfidentialLedger
     moduledoc): EVERY append commits; identical contents mint a NEW
     transactionId -- the retired `duplicate contents -> 409
     LedgerItemAlreadyExists` pin was premise rot. The gate now pins the
     real-Azure law: duplicate contents -> 201 with a NEW transactionId,
     chain extended, no txid reuse.

  2. List-face transit: GET /app/transactions is in inversion transit to the
     ACL router (lib/smalt/confidential_ledger/router.ex, KD-170 dedicated
     port); on the egress face it currently answers 404 QueueNotFound, so the
     gate no longer pins the list face: it walks the chain per-tx
     (GET /app/transactions/{txId}) plus /latest.

Positive: append three distinct entries + one duplicate (same contents as
the first) via POST /app/transactions on a live substrate, then verify:
  per-tx fetch of every minted transactionId -> 200
  merkle_root == sha256(prev_hash <> data_hash)      (hex, lowercase)
  receipt[i].prev_hash == receipt[i-1].merkle_root  (first prev = 64 zeros)
  transactionId == "<seq>.1", monotonic seqs (duplicate extends to <n+1>.1)
  duplicate contents -> 201 with a NEW transactionId (no txid reuse)
  GET /app/transactions/latest -> the duplicate (highest seq)

Negative fixtures: broken prev-link, wrong root, non-zero genesis, broken
seq, duplicate deduped (409 -- the RETIRED behavior must be refused), txid
reuse, latest mismatch, per-tx fetch not-200 -- each must be refused.

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
    txids = [r.get("transactionId") for r in receipts]

    # Real-Azure no-dedupe law (2026-10-25): every append commits; identical
    # contents mint a NEW transactionId. The retired 409-dedupe pin must be
    # refused by the verdict (fixture: dup-deduped).
    s_dup, _, dup_body = common.http(egress, "POST", "/app/transactions", ENTRIES[0])
    dup_receipt = dup_body if s_dup == 201 else {}
    dup_tx = dup_receipt.get("transactionId")

    # Walk the chain per-tx instead of pinning the (in-transit) list face.
    chain = []
    fetch_statuses = []
    for tx in txids + [dup_tx]:
        s_tx, _, body = common.http(egress, "GET", "/app/transactions/%s" % tx)
        fetch_statuses.append(s_tx)
        chain.append(body if s_tx == 200 else {})

    s_latest, _, latest = common.http(egress, "GET", "/app/transactions/latest")
    return {
        "appends": statuses,
        "receipts": receipts,
        "dup_status": s_dup,
        "dup_receipt": dup_receipt,
        "fetch_statuses": fetch_statuses,
        "listed": chain,
        "latest_status": s_latest,
        "latest": latest if s_latest == 200 else {},
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

    # Real-Azure no-dedupe law: duplicate contents commit with a NEW txid.
    check(obs.get("dup_status") == 201,
          "duplicate contents commit -> 201 (real-Azure no-dedupe law)")
    dup_tx = obs.get("dup_receipt", {}).get("transactionId")
    appended_ids = [r.get("transactionId") for r in receipts]
    check(bool(dup_tx) and dup_tx not in appended_ids,
          f"duplicate mints a NEW transactionId (got {dup_tx!r}, no reuse)")

    fetch_statuses = obs.get("fetch_statuses", [])
    check(len(fetch_statuses) == len(appended_ids) + 1
          and all(s == 200 for s in fetch_statuses),
          "per-tx fetch of every chain link -> 200")

    listed = obs.get("listed", [])
    check(len(listed) == len(appended_ids) + 1,
          "chain walk fetched every link incl. the duplicate")

    s_latest = obs.get("latest_status")
    latest_tx = obs.get("latest", {}).get("transactionId")
    check(s_latest == 200 and latest_tx == dup_tx,
          f"latest is the duplicate append (got {s_latest}, tx {latest_tx!r})")

    prev = ZERO_HASH
    seq = 0
    chain_ok = True
    chain_msg = "chain continuity holds incl. duplicate link"
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


def _safe_idx(lst, i):
    return lst[i] if isinstance(lst, list) and len(lst) > i else None


def _mutate(obs, fn):
    import copy
    o = copy.deepcopy(obs)
    fn(o)
    return o


def mutate_fixtures(obs):
    def broken_link(o):
        o["listed"][1]["prev_hash"] = "f" * 64

    def wrong_root(o):
        o["listed"][2]["merkle_root"] = "a" * 64

    def tampered_contents(o):
        o["listed"][0]["contents"] = {"k": "tampered"}

    def nonzero_genesis(o):
        o["latest_status"] = None
        o["listed"][0]["prev_hash"] = "1" * 64

    def broken_seq(o):
        # SHIM-COURT-style negative fixture: transactionId seq must be
        # monotonic "<seq>.1"; breaking the seq must be detected.
        o["listed"][1]["transactionId"] = "1.1"

    def dup_deduped(o):
        # The RETIRED 409-dedupe behavior must itself be refused now.
        o["dup_status"] = 409

    def dup_txid_reuse(o):
        if isinstance(o.get("dup_receipt"), dict) and o["dup_receipt"]:
            o["dup_receipt"]["transactionId"] = o["receipts"][0]["transactionId"]
        else:
            o["dup_receipt"] = {}

    def latest_mismatch(o):
        o["latest"] = {"transactionId": "9.9"}

    def fetch_not_200(o):
        if o.get("fetch_statuses"):
            o["fetch_statuses"][0] = 404
        else:
            o["fetch_statuses"] = []

    def short_chain(o):
        o["listed"] = o["listed"][:2]

    return [(n, _mutate(obs, f)) for n, f in
            [("broken-link", broken_link), ("wrong-root", wrong_root),
             ("tampered-contents", tampered_contents),
             ("nonzero-genesis", nonzero_genesis),
             ("broken-seq", broken_seq),
             ("dup-deduped", dup_deduped),
             ("dup-txid-reuse", dup_txid_reuse),
             ("latest-mismatch", latest_mismatch),
             ("fetch-not-200", fetch_not_200),
             ("short-chain", short_chain)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("ledger-chain", capture, verdict, mutate_fixtures))
