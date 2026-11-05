#!/usr/bin/env python3
"""Invariant gate: Confidential Ledger Merkle-chain continuity (core).

v26.11.6 lane-11 retarget (CORE SWAP LANDED): the Merkle link is now
chain-gen-2 BLAKE3 -- link_digest = BLAKE3("SMALT/AOQ-LINK/v2" ||
raw32(prev_root) || seq::u64-BE || raw32(data_hash) || sub_ledger_id) --
re-derivable here through the vendored, import-KAT-fenced gates/blake3_ref.py.
The former "PENDING THE CORE SWAP" docstring note is RETIRED by this swap
(receipt: docs/jira/v26.11.6/receipts/lane11-blake3-chain-retarget.md).
Gen-1 receipts (no chain_gen key) verify forever under the legacy
sha256 hex-fold law; verdict() dispatches on receipt["chain_gen"] || 1.

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
import blake3_ref  # import-time BLAKE3 KAT: a broken hash law exits nonzero
import common

ZERO_HASH = "0" * 64
LINK_DOMAIN = "SMALT/AOQ-LINK/v2"
ENTRIES = [{"k": "gate-a"}, {"k": "gate-b"}, {"k": "gate-c"}]


def data_hash(contents):
    canonical = json.dumps(contents, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def link_digest(prev_root_hex, seq, data_hash_hex, sub_ledger_id):
    """Chain-gen-2 Merkle link (byte-exact with LedgerWriter.link_digest/4)."""
    prev_raw = bytes.fromhex(prev_root_hex)
    dh_raw = bytes.fromhex(data_hash_hex)
    return blake3_ref.blake3_hex(
        LINK_DOMAIN.encode() + prev_raw + seq.to_bytes(8, "big") + dh_raw
        + sub_ledger_id.encode())


def legacy_link(prev_root_hex, data_hash_hex):
    """Chain-gen-1 Merkle link (sha256 hex-fold, verifies forever)."""
    return hashlib.sha256((prev_root_hex + data_hash_hex).encode()).hexdigest()


def receipt_link(receipt):
    """Re-derive the link under the receipt's own chain generation."""
    gen = receipt.get("chain_gen", 1)
    seq = int(str(receipt.get("transactionId", "0")).split(".")[0])
    if gen == 2:
        return link_digest(receipt.get("prev_hash", ZERO_HASH), seq,
                           receipt.get("data_hash", ""), 
                           receipt.get("subLedgerId", ""))
    if gen == 1:
        return legacy_link(receipt.get("prev_hash", ZERO_HASH),
                           receipt.get("data_hash", ""))
    return None


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
        # Ledger binding pin: the face appends to one named ledger; every
        # chain receipt must carry it (ledger-id-unbound fixture kills an
        # unbound verifier).
        "ledger": receipts[0].get("subLedgerId") if receipts else None,
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
    latest_tx = (obs.get("latest") or {}).get("transactionId")
    check(s_latest == 200 and latest_tx == dup_tx,
          f"latest is the duplicate append (got {s_latest}, tx {latest_tx!r})")

    prev = ZERO_HASH
    seq = 0
    chain_ok = True
    chain_msg = "chain continuity holds incl. duplicate link (gen dispatch)"
    for r in listed:
        seq += 1
        tx = r.get("transactionId", "")
        if tx != f"{seq}.1":
            chain_ok, chain_msg = False, f"{tx}: tx id {tx!r} != {seq}.1"
            break
        dh = data_hash(r.get("contents", {}))
        if r.get("data_hash") != dh:
            chain_ok, chain_msg = False, f"{tx}: data_hash mismatch"
            break
        if r.get("prev_hash") != prev:
            chain_ok, chain_msg = False, f"{tx}: prev_hash does not link"
            break
        root = receipt_link(r)
        if root is None:
            chain_ok, chain_msg = False, f"{tx}: unknown chain_gen"
            break
        if r.get("merkle_root") != root:
            chain_ok, chain_msg = False, f"{tx}: merkle_root re-derivation mismatch"
            break
        if r.get("subLedgerId") != obs.get("ledger"):
            chain_ok, chain_msg = False, f"{tx}: subLedgerId not bound to {obs.get('ledger')}"
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

    def gen_erase(o):
        # Kills the ignore-chain_gen mutant: erasing the field drops the
        # receipt to gen-1 law, under which its gen-2 root mismatches.
        o["listed"][0].pop("chain_gen", None)

    def wrong_gen(o):
        # Kills the stamp-back mutant: chain_gen 2 re-stamped as 1.
        o["listed"][1]["chain_gen"] = 1

    def seq_not_in_digest(o):
        # Kills the seq-unbound verifier: forge a SELF-CONSISTENT chain whose
        # roots were computed with the seq omitted from the link digest. Only
        # a verifier that binds seq re-derives a mismatch.
        prev = o["listed"][0].get("prev_hash", ZERO_HASH)
        for r in o["listed"]:
            dh = r.get("data_hash", "")
            prev_raw = bytes.fromhex(prev)
            dh_raw = bytes.fromhex(dh)
            no_seq = blake3_ref.blake3_hex(
                LINK_DOMAIN.encode() + prev_raw + dh_raw
                + r.get("subLedgerId", "").encode())
            r["merkle_root"] = no_seq
            r["prev_hash"] = prev
            prev = no_seq

    def ledger_id_unbound(o):
        # Kills the ledger-unbound verifier: rebind every receipt to a
        # foreign subLedgerId and recompute all roots so the chain is fully
        # self-consistent under an unbound law; only the obs["ledger"] pin
        # catches it.
        for r in o["listed"]:
            r["subLedgerId"] = "attacker-ledger"
        prev = ZERO_HASH
        for i, r in enumerate(o["listed"], 1):
            dh = r.get("data_hash", "")
            r["merkle_root"] = link_digest(prev, i, dh, "attacker-ledger")
            r["prev_hash"] = prev
            prev = r["merkle_root"]

    return [(n, _mutate(obs, f)) for n, f in
            [("broken-link", broken_link), ("wrong-root", wrong_root),
             ("tampered-contents", tampered_contents),
             ("nonzero-genesis", nonzero_genesis),
             ("broken-seq", broken_seq),
             ("dup-deduped", dup_deduped),
             ("dup-txid-reuse", dup_txid_reuse),
             ("latest-mismatch", latest_mismatch),
             ("fetch-not-200", fetch_not_200),
             ("short-chain", short_chain),
             ("gen-erase", gen_erase),
             ("wrong-gen", wrong_gen),
             ("seq-not-in-digest", seq_not_in_digest),
             ("ledger-id-unbound", ledger_id_unbound)]]

if __name__ == "__main__":
    sys.exit(common.run_gate("ledger-chain", capture, verdict, mutate_fixtures))
