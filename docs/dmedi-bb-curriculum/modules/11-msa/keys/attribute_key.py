#!/usr/bin/env python3
"""Solution key — Module 11: attribute agreement analysis (kappa, misclassification).

Re-derives kappa and false-accept/false-reject counts from the raw CSV.
Exit 0 = key verified.
"""
import sys, os
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CSV = os.path.join(ROOT, "data", "attribute-inspectors.csv")

rows = []
with open(CSV) as f:
    next(f)
    for line in f:
        ins, tr, p, ref, v = line.strip().split(",")
        rows.append((ins, int(tr), int(p), int(ref), int(v)))
assert len(rows) == 300, f"expected 300 rows (3 inspectors x 2 trials x 50 parts), got {len(rows)}"

def kappa2(a, b):
    a = np.asarray(a); b = np.asarray(b)
    po = (a == b).mean()
    pe = (a == 1).mean() * (b == 1).mean() + (a == 0).mean() * (b == 0).mean()
    return (po - pe) / (1 - pe)

def stats_for(ins, tr):
    d = [(r[3], r[4]) for r in rows if r[0] == ins and r[1] == tr]
    ref = np.array([x[0] for x in d]); v = np.array([x[1] for x in d])
    return dict(
        kappa_vs_ref=round(float(kappa2(v, ref)), 3),
        within_kappa=round(float(kappa2(
            [x[1] for x in [(r[3], r[4]) for r in rows if r[0] == ins and r[1] == 1]],
            [x[1] for x in [(r[3], r[4]) for r in rows if r[0] == ins and r[1] == 2]])), 3),
        false_accept=int(((v == 0) & (ref == 1)).sum()),
        false_reject=int(((v == 1) & (ref == 0)).sum()),
    )

print("ATTRIBUTE KEY (re-derived from data/attribute-inspectors.csv, seed 713)")
ok_ordering = True
for ins in ["Insp1", "Insp2", "Insp3"]:
    s1 = stats_for(ins, 1); s2 = stats_for(ins, 2)
    print(f"  {ins} trial1: kappa_vs_ref={s1['kappa_vs_ref']} false_accept={s1['false_accept']} false_reject={s1['false_reject']}")
    print(f"  {ins} trial2: kappa_vs_ref={s2['kappa_vs_ref']} within-inspector kappa={s1['within_kappa']}")
    assert -1 <= s1["kappa_vs_ref"] <= 1 and -1 <= s1["within_kappa"] <= 1
# teaching ordering: Insp1 acceptable, Insp3 poor + internally inconsistent
k1 = stats_for("Insp1", 1)["kappa_vs_ref"]; k3 = stats_for("Insp3", 1)["kappa_vs_ref"]
w3 = stats_for("Insp3", 1)["within_kappa"]
assert k1 > 0.6, "Insp1 must be the acceptable inspector (kappa > 0.6)"
assert k3 < 0.6, "Insp3 must be the weak inspector"
assert w3 < 0.2, "Insp3 within-inspector kappa must demonstrate inconsistency (< 0.2)"
pooled_ref = np.array([r[3] for r in rows if r[1] == 1])
pooled_v = np.array([r[4] for r in rows if r[1] == 1])
print(f"  pooled trial-1 kappa vs reference = {round(float(kappa2(pooled_v, pooled_ref)), 3)}")
print("  verdict: Insp1 acceptable; Insp2 marginal; Insp3 retrain-and-recheck (poor agreement with")
print("           reference AND poor within-inspector repeatability).")
sys.exit(0)
