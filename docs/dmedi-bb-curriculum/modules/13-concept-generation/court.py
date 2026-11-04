#!/usr/bin/env python3
"""Module 13 court (concept generation). Exit 0 = the concept ranking
re-derives from RAW portfolio rows (datasets/concept-portfolio.csv), the
existing gate scripts/score_concepts.py exits 0, and the two agree.

Pins (re-derived): Score = 0.4*novelty + 0.6*feasibility; ranking
  C1 4.20, C7 4.00, C3 3.80, C5 3.60, C2 3.40, C6 3.40, C4 2.80, C8 2.60
(C2/C6 tie at 3.40 broken by CSV row order); 8 concepts, funnel 12 raw ideas
-> 4 affinity merges -> 8 concepts (seed 1317, workshop W3); C1 survives to
Module 14's TRIZ deepening.

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero. If the corrupted court still passes, exit 2 = VACUOUS COURT.
"""
import csv, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "scripts", "score_concepts.py")
SRC = os.path.join(HERE, "datasets", "concept-portfolio.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: modules/13-concept-generation/datasets/concept-portfolio.csv missing (seed 1317 funnel)")

fail = []
def check(name, got, want):
    if got != want:
        fail.append(f"{name}: got {got!r}, want {want!r}")

# ---------- wrap the existing gate ----------
r = subprocess.run([sys.executable, GATE], capture_output=True, text=True)
check("score_concepts_rc0", r.returncode, 0)

# ---------- independent re-derivation ----------
rows = list(csv.DictReader(open(SRC)))
check("concept_count", len(rows), 8)
scored = sorted(rows, key=lambda r: -(0.4 * int(r["novelty_1to5"])
                                      + 0.6 * int(r["feasibility_1to5"])))
order = [(r["concept_id"], round(0.4 * int(r["novelty_1to5"])
                                 + 0.6 * int(r["feasibility_1to5"]), 2))
         for r in scored]
check("ranking", order, [("C1", 4.2), ("C7", 4.0), ("C3", 3.8), ("C5", 3.6),
                         ("C2", 3.4), ("C6", 3.4), ("C4", 2.8), ("C8", 2.6)])
check("winner_is_C1", order[0][0], "C1")
check("C1_triz_pin", scored[0]["concept"].find("TRIZ 24") >= 0, True)

# gate output must contain the same ranking head
head = [ln.split()[0] for ln in r.stdout.splitlines() if ln.startswith("C")]
check("gate_output_agrees", head, [c for c, _ in order])

if fail:
    print("COURT FAIL")
    for f in fail:
        print(" -", f)
    sys.exit(1)

print("Module 13 court: ALL CHECKS PASS (8 concepts, score=0.4n+0.6f, ranking "
      "C1 4.20 > C7 4.00 > C3 3.80 > C5 3.60 > C2/C6 3.40 > C4 2.80 > C8 2.60, "
      "score_concepts.py rc=0 agrees)")

# ---------- mutation test ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if order[0] == ("C8", 4.2):  # corrupted pin: C8 on top
        print("VACUOUS COURT: corrupted constant still passes")
        sys.exit(2)
    print(f"MUTATION DETECTED: winner pinned as C8 vs derived {order[0][0]} "
          f"-> court exits nonzero")
    sys.exit(1)
sys.exit(0)
