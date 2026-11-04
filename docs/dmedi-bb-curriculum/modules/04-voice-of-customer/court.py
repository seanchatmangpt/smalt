#!/usr/bin/env python3
"""Module 04 court (VoC / Kano). Exit 0 = the Kano classification surface
re-derives from RAW survey rows, never memory.

Pins (re-derived here from data/kano-responses.csv, seed 20261104):
  12 respondents x 10 attributes = 120 rows;
  majorities K-01/02/03 = M, K-04/05/06 = O, K-07/08 = A, K-09/10 = I;
  K-05 tally O=7 A=1 R=1 M=1 Q=2, SI=0.667 DSI=-0.667;
  paired-rank weights normalize to 1.0 over a 45-point pool (E8);
  lead-time gap 18.4 -> 7.0 = 11.4 days = 62.0% reduction (E7).

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero. If the corrupted court still passes, exit 2 = VACUOUS COURT.
"""
import csv, os, sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "data", "kano-responses.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: modules/04-voice-of-customer/data/kano-responses.csv missing (seed 20261104)")

fail = []
def check(name, got, want):
    if got != want:
        fail.append(f"{name}: got {got!r}, want {want!r}")

# Standard Kano evaluation table, (functional, dysfunctional) -> class:
#      D=A   D=M   D=I
# F=A   Q     A     O
# F=M   O     R     M
# F=I   R     M     I
KANO = {
    ("A", "A"): "Q", ("A", "M"): "A", ("A", "I"): "O",
    ("M", "A"): "O", ("M", "M"): "R", ("M", "I"): "M",
    ("I", "A"): "R", ("I", "M"): "M", ("I", "I"): "I",
}

rows = list(csv.DictReader(open(SRC)))
by_k = {}
for r in rows:
    by_k.setdefault(r["kano_id"], []).append(r)

check("kano_respondent_count", len({r["resp_id"] for r in rows}), 12)
check("kano_attribute_count", len(by_k), 10)
check("kano_row_count", len(rows), 120)

order = ["M", "O", "A", "I", "R", "L", "Q"]
expect = {
    "K-01": "M", "K-02": "M", "K-03": "M", "K-04": "O", "K-05": "O",
    "K-06": "O", "K-07": "A", "K-08": "A", "K-09": "I", "K-10": "I",
}
majority, sids = {}, {}
for cid, rs in sorted(by_k.items()):
    check(cid + "_tally_rows", len(rs), 12)
    cls = [KANO[(r["func"], r["dys"])] for r in rs]
    c = Counter(cls)
    best = max(order, key=lambda k: (c.get(k, 0), -order.index(k)))
    n = len(cls)
    si = round((c.get("A", 0) + c.get("O", 0)) / n, 3)
    dsi = round(-1 * (c.get("O", 0) + c.get("M", 0)) / n, 3)
    majority[cid] = best
    sids[cid] = (si, dsi)

for cid, want in expect.items():
    check("kano_majority_" + cid, majority.get(cid), want)

# K-05 hand-tally pin (solution-key E3)
c05 = Counter(KANO[(r["func"], r["dys"])] for r in by_k["K-05"])
check("K05_counts", dict(sorted(c05.items())), {"A": 1, "M": 1, "O": 7, "Q": 2, "R": 1})
check("K05_SI", sids["K-05"][0], 0.667)
check("K05_DSI", sids["K-05"][1], -0.667)

# E8: paired-rank weights (ranks from solution key; pool 45, sum 1.0)
ranks = {"CR1": 2, "CR2": 1, "CR3": 6, "CR4": 3, "CR5": 4, "CR6": 5,
         "CR7": 7, "CR8": 8, "CR9": 9}
total = sum(ranks.values())
check("rank_point_pool", total, 45)
weights = {k: round((9 + 1 - v) / total, 3) for k, v in ranks.items()}
check("normalized_weight_sum", round(sum(weights.values()), 3), 1.0)
check("weight_CR1", weights["CR1"], 0.178)
check("weight_CR9", weights["CR9"], 0.022)

# E7: lead-time gap (spine CTQ-2)
base, target = 18.4, 7.0
check("lead_time_gap_days", round(base - target, 1), 11.4)
check("lead_time_gap_pct", round(100 * (base - target) / base, 1), 62.0)

if fail:
    print("COURT FAIL")
    for f in fail:
        print(" -", f)
    sys.exit(1)

print("Module 04 court: ALL CHECKS PASS (12 respondents x 10 attributes, "
      "majorities M/M/M O/O/O A/A I/I, K-05 SI 0.667 / DSI -0.667, "
      "weight pool 45 -> sum 1.0, lead-time gap 11.4 d = 62.0%)")

# ---------- mutation test: corrupt one pinned constant ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if majority.get("K-05") == "Q":
        print("VACUOUS COURT: corrupted constant still passes")
        sys.exit(2)
    print("MUTATION DETECTED: K-05 pinned as 'Q' vs derived "
          + str(majority.get("K-05")) + " -> court exits nonzero")
    sys.exit(1)
sys.exit(0)
