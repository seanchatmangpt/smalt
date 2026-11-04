#!/usr/bin/env python3
"""Lane 02 — Module 05 QFD data writer. Deterministic (authored design data;
no RNG; seed N/A — see MANIFEST). Rerun -> byte-identical CSVs.

Consumes module 04's kano-responses.csv ONLY through the weights contract
(CR ids, ranks); importance points are re-derived, never remembered.
"""
import csv, os

BASE = "/Users/sac/smalt/docs/dmedi-bb-curriculum"
D = f"{BASE}/modules/05-qfd/data"

# ---- CR table (ties to module 04: Kano id + class + paired rank) ----
# ID-NAMESPACE LAW: module 04's Kano attributes live in the K-01..K-10
# namespace (kano-responses.csv). The spine_ctq column names the running-case
# spine CTQ each CR DERIVES INTO (RUNNING-CASE.md owns CTQ-1/2/3):
#   CR1 <- K-01 -> CTQ-1 (bore); CR5 <- K-05 -> CTQ-2 (lead time);
#   CR6 <- K-06 -> CTQ-3 (cost). Blank spine_ctq = feeds ECs only, no spine CTQ.
CRS = [
    # id, name, kano_id, spine_ctq, kano, rank
    ("CR1", "bore-diameter-in-spec",         "K-01",  "CTQ-1", "M", 2),
    ("CR2", "no-leaking-hydraulic-ports",    "K-02",  "",      "M", 1),
    ("CR3", "certification-paperwork",       "K-03",  "",      "M", 6),
    ("CR4", "bore-surface-finish-low-Ra",    "K-04",  "",      "O", 3),
    ("CR5", "order-to-ship-lead-time",       "K-05",  "CTQ-2", "O", 4),
    ("CR6", "competitive-unit-cost",         "K-06",  "CTQ-3", "O", 5),
    ("CR7", "laser-etched-serialization",    "K-07",  "",      "A", 7),
    ("CR8", "live-production-dashboard",     "K-08",  "",      "A", 8),
    ("CR9", "weekly-quality-trend-report",   "K-10",  "",      "I", 9),
]

# ---- Engineering characteristics ----
ECS = [
    ("EC1", "bore-diameter-tolerance-mm",  "12.000 +/- 0.008 (internal guard-band)", "spec +/- 0.025; Cpk 0.72 pinned"),
    ("EC2", "surface-finish-Ra-um",        "<= 0.8", "1.6"),
    ("EC3", "leak-test-fail-ppm",          "0",      "1200"),
    ("EC4", "order-to-ship-lead-time-d",   "<= 7",   "18.4"),
    ("EC5", "unit-cost-usd",               "<= 28.50", "41.80"),
    ("EC6", "etch-first-pass-readable-pct", ">= 95", "85"),
]

# ---- Relationship matrix (9 strong / 3 moderate / 1 weak / blank none) ----
MATRIX = {
    "CR1": {"EC1": 9, "EC2": 3, "EC5": 3},
    "CR2": {"EC1": 1, "EC3": 9, "EC5": 1},
    "CR3": {"EC4": 3, "EC6": 1},
    "CR4": {"EC1": 3, "EC2": 9},
    "CR5": {"EC4": 9},
    "CR6": {"EC1": 1, "EC2": 1, "EC5": 9},
    "CR7": {"EC6": 9, "EC4": 1},
    "CR8": {"EC4": 1, "EC6": 1},
    "CR9": {"EC4": 1, "EC6": 1},
}

# ---- Correlation roof (all 15 EC pairs; scores ++/+/0/-/--) ----
ROOF = {
    ("EC1", "EC2"): "+",  ("EC1", "EC3"): "+",  ("EC1", "EC4"): "0",
    ("EC1", "EC5"): "--", ("EC1", "EC6"): "0",
    ("EC2", "EC3"): "0",  ("EC2", "EC4"): "0",  ("EC2", "EC5"): "-",
    ("EC2", "EC6"): "0",
    ("EC3", "EC4"): "0",  ("EC3", "EC5"): "-",  ("EC3", "EC6"): "0",
    ("EC4", "EC5"): "+",  ("EC4", "EC6"): "0",
    ("EC5", "EC6"): "-",
}

# ---- Secondary transactional QFD: insurance claims SLA ----
CLAIM_CRS = [
    ("C1", "fast-claim-decision",        9, 1),
    ("C2", "payment-accuracy",           8, 2),
    ("C3", "status-transparency",        3, 5),
    ("C4", "digital-submission",         6, 4),
    ("C5", "plain-language-comms",       5, 6),
    ("C6", "data-security",              9, 3),
]
CLAIM_ECS = [
    ("T1", "decision-cycle-time-d",      "<= 3", "12"),
    ("T2", "claim-file-first-pass-yield-pct", ">= 95", "71"),
    ("T3", "rework-loops-per-claim",     "<= 0.2", "1.8"),
    ("T4", "digital-adoption-pct",       ">= 80", "38"),
    ("T5", "complaints-per-1k-claims",   "<= 2.0", "6.5"),
    ("T6", "audit-exception-pct",        "<= 2", "9"),
]
CLAIM_MATRIX = {
    "C1": {"T1": 9, "T2": 3, "T3": 3},
    "C2": {"T2": 9, "T3": 3, "T6": 3},
    "C3": {"T1": 1, "T3": 3, "T5": 3},
    "C4": {"T4": 9, "T1": 3},
    "C5": {"T5": 9, "T2": 1},
    "C6": {"T6": 9, "T4": 3},
}
CLAIM_ROOF = {
    ("T1", "T2"): "+",  ("T1", "T3"): "--", ("T1", "T4"): "+",
    ("T1", "T5"): "0",  ("T1", "T6"): "0",
    ("T2", "T3"): "--", ("T2", "T4"): "+",  ("T2", "T5"): "0",
    ("T2", "T6"): "0",
    ("T3", "T4"): "0",  ("T3", "T5"): "+",  ("T3", "T6"): "0",
    ("T4", "T5"): "+",  ("T4", "T6"): "0",
    ("T5", "T6"): "+",
}


def largest_remainder(items, total=100):
    """items: list of (key, value). Returns {key: int} summing to exactly total
    (largest-remainder allocation, exact Fraction arithmetic — no float ties)."""
    from fractions import Fraction
    s = Fraction(sum(Fraction(v) for _, v in items))
    scaled = [(k, Fraction(v) * total / s) for k, v in items]
    base = {k: int(v) for k, v in scaled}
    frac = sorted(((v - base[k], k) for k, v in scaled), reverse=True)
    for _, k in frac[: total - sum(base.values())]:
        base[k] += 1
    return base


def main():
    # weights CSV (module 04 contract)
    n = len(CRS)
    pool = n * (n + 1) / 2
    pts = largest_remainder([(c[0], (10 - c[5]) / pool) for c in CRS])
    with open(f"{D}/qfd-cppc-weights.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["cr_id", "cr_name", "kano_id", "spine_ctq", "kano_class", "rank", "weight", "points100"])
        for cid, name, kano_id, spine_ctq, kano, rank in CRS:
            w.writerow([cid, name, kano_id, spine_ctq, kano, rank,
                        round((10 - rank) / pool, 3), pts[cid]])
    # matrix CSV
    with open(f"{D}/qfd-cppc-matrix.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["cr_id"] + [e[0] for e in ECS])
        for cid, *_ in CRS:
            w.writerow([cid] + [MATRIX[cid].get(e[0], "") for e in ECS])
    # roof CSV
    with open(f"{D}/qfd-cppc-roof.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["ec_a", "ec_b", "score"])
        for (a, b), s in sorted(ROOF.items()):
            w.writerow([a, b, s])
    # EC targets CSV
    with open(f"{D}/qfd-cppc-targets.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["ec_id", "ec_name", "unit", "baseline", "target"])
        for eid, name, tgt, base in ECS:
            w.writerow([eid, name, "", base, tgt])
    # claims weights
    tw = largest_remainder([(c[0], c[2]) for c in CLAIM_CRS])
    with open(f"{D}/qfd-claims-weights.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["cr_id", "cr_name", "rating_1to10", "weight_pct"])
        for cid, name, rating, _ in CLAIM_CRS:
            w.writerow([cid, name, rating, tw[cid]])
    # claims matrix + roof
    with open(f"{D}/qfd-claims-matrix.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["cr_id"] + [e[0] for e in CLAIM_ECS])
        for cid, *_ in CLAIM_CRS:
            w.writerow([cid] + [CLAIM_MATRIX[cid].get(e[0], "") for e in CLAIM_ECS])
    with open(f"{D}/qfd-claims-roof.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["ec_a", "ec_b", "score"])
        for (a, b), s in sorted(CLAIM_ROOF.items()):
            w.writerow([a, b, s])
    print("wrote 6 CSVs to", D)


if __name__ == "__main__":
    main()
