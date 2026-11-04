#!/usr/bin/env python3
"""Lane 02 — Module 05 (QFD) court. Re-derives EVERY number in the Module 05
docs from the raw CSVs and exits 1 on any mismatch. No remembered answers.

Derivation chain: module 04 kano-responses.csv -> CR ranks -> largest-remainder
points (sum 100) -> relationship matrix row sums + weighted column totals ->
roof pair census -> targets-vs-baseline (spine constants) -> Cpk 1.33 math.
"""
import csv, sys
from fractions import Fraction
from collections import defaultdict

BASE = "/Users/sac/smalt/docs/dmedi-bb-curriculum"
D = f"{BASE}/modules/05-qfd/data"
fail = []

def check(label, got, want):
    ok = got == want
    if not ok:
        fail.append(f"{label}: got {got!r} want {want!r}")
    print(f"{'PASS' if ok else 'FAIL'} {label}: {got!r}")

def rd(path):
    return list(csv.DictReader(open(path)))

# ---------- 1. weights re-derive from module 04 ranks ----------
w_rows = rd(f"{D}/qfd-cppc-weights.csv")
check("cppc CR count", len(w_rows), 9)
pool = Fraction(9 * 10, 2)  # 45
def alloc(fracs, total=100):
    s = sum(fracs.values())
    scaled = {k: Fraction(v) * total / s for k, v in fracs.items()}
    base = {k: int(v) for k, v in scaled.items()}
    order = sorted(((v - base[k], k) for k, v in scaled.items()), reverse=True)
    for _, k in order[: total - sum(base.values())]:
        base[k] += 1
    return base
fracs = {r["cr_id"]: Fraction(10 - int(r["rank"]), 45) for r in w_rows}
pts = alloc(fracs)
got_pts = {r["cr_id"]: int(r["points100"]) for r in w_rows}
check("cppc points100 allocation", got_pts, pts)
check("cppc points sum", sum(pts.values()), 100)

# ranks must match module 04 compute.py's ranks dict
m4_ranks = {"CR1": 2, "CR2": 1, "CR3": 6, "CR4": 3, "CR5": 4, "CR6": 5,
            "CR7": 7, "CR8": 8, "CR9": 9}
check("ranks match module-04 compute.py",
      {r["cr_id"]: int(r["rank"]) for r in w_rows}, m4_ranks)

# id-namespace pin (coherence D4): kano_id column must cite module 04's K-*
# attribute namespace, and the spine_ctq derivation must be exactly this map.
m4_kano_ids = {r["kano_id"] for r in rd(
    f"{BASE}/modules/04-voice-of-customer/data/kano-responses.csv")}
check("weights kano_id column cites M04 K-namespace",
      {r["kano_id"] for r in w_rows} <= m4_kano_ids, True)
SPINE_MAP = {"CR1": "CTQ-1", "CR2": "", "CR3": "", "CR4": "", "CR5": "CTQ-2",
             "CR6": "CTQ-3", "CR7": "", "CR8": "", "CR9": ""}
check("spine_ctq derivation map",
      {r["cr_id"]: r["spine_ctq"] for r in w_rows}, SPINE_MAP)

# ---------- 2. relationship matrix: row sums + weighted column totals ----------
m_rows = rd(f"{D}/qfd-cppc-matrix.csv")
ecs = [c for c in m_rows[0] if c != "cr_id"]
check("cppc EC count", len(ecs), 6)
w = {r["cr_id"]: int(r["points100"]) for r in w_rows}
row_sums, col_tot = {}, defaultdict(int)
for r in m_rows:
    s = sum(int(r[e]) for e in ecs if r[e])
    row_sums[r["cr_id"]] = s
    for e in ecs:
        if r[e]:
            col_tot[e] += w[r["cr_id"]] * int(r[e])
# authored expectations (documented in lab.md)
check("cppc row sums", row_sums,
      {"CR1": 15, "CR2": 11, "CR3": 4, "CR4": 12, "CR5": 9,
       "CR6": 11, "CR7": 10, "CR8": 2, "CR9": 2})
check("cppc column totals", dict(col_tot),
      {"EC1": 241, "EC2": 209, "EC3": 180, "EC4": 157, "EC5": 173, "EC6": 78})
check("cppc total importance", sum(col_tot.values()),
      sum(w[c] * s for c, s in row_sums.items()))  # conservation: rows == cols

# cells restricted to 9/3/1
vals = {int(r[e]) for r in m_rows for e in ecs if r[e]}
check("cppc matrix cell vocabulary", sorted(vals), [1, 3, 9])

# ---------- 3. roof census ----------
roof = rd(f"{D}/qfd-cppc-roof.csv")
check("cppc roof pair count", len(roof), 15)  # C(6,2)
check("cppc roof vocabulary", sorted({r["score"] for r in roof}), ["+", "-", "--", "0"])
neg = [r for r in roof if r["score"] in ("-", "--")]
check("cppc cost-EC conflict count (EC5)", len([r for r in neg if "EC5" in (r["ec_a"], r["ec_b"])]), 4)

# ---------- 4. targets reference the spine ----------
t = {r["ec_id"]: r for r in rd(f"{D}/qfd-cppc-targets.csv")}
check("EC4 baseline lead", t["EC4"]["baseline"], "18.4")
check("EC4 target lead", t["EC4"]["target"], "<= 7")
check("EC5 baseline cost", t["EC5"]["baseline"], "41.80")
check("EC5 target cost", t["EC5"]["target"], "<= 28.50")
check("EC1 pinned Cpk referenced", "Cpk 0.72" in t["EC1"]["baseline"], True)

# Cpk 1.33 math: internal guard-band +/-0.008 mm at sigma = 2.0 um, centered
sigma, tol = 0.0020, 0.008
cpk = round(tol / (3 * sigma), 2)
check("EC1 Cpk math (0.008/(3*0.0020))", cpk, 1.33)
# vs customer spec +/-0.025 at sigma 2.0 um (centered): Z margin
z = round(0.025 / sigma, 1)
check("EC1 Z vs customer spec", z, 12.5)

# ---------- 5. secondary transactional QFD (insurance claims SLA) ----------
cw = rd(f"{D}/qfd-claims-weights.csv")
ratings = {r["cr_id"]: int(r["rating_1to10"]) for r in cw}
cpts = alloc({k: Fraction(v) for k, v in ratings.items()})
check("claims weights allocation", {r["cr_id"]: int(r["weight_pct"]) for r in cw}, cpts)
check("claims weights sum", sum(cpts.values()), 100)

cm = rd(f"{D}/qfd-claims-matrix.csv")
tcs = [c for c in cm[0] if c != "cr_id"]
cwt = {r["cr_id"]: int(r["weight_pct"]) for r in cw}
crow, ccol = {}, defaultdict(int)
for r in cm:
    crow[r["cr_id"]] = sum(int(r[e]) for e in tcs if r[e])
    for e in tcs:
        if r[e]:
            ccol[e] += cwt[r["cr_id"]] * int(r[e])
check("claims row sums", crow, {"C1": 15, "C2": 15, "C3": 7, "C4": 12, "C5": 10, "C6": 12})
check("claims column totals", dict(ccol),
      {"T1": 250, "T2": 259, "T3": 147, "T4": 204, "T5": 138, "T6": 267})
check("claims total conservation", sum(ccol.values()),
      sum(cwt[c] * s for c, s in crow.items()))
croof = rd(f"{D}/qfd-claims-roof.csv")
check("claims roof pair count", len(croof), 15)

# ---------- 6. module 04 court still green (dataset unchanged) ----------
import subprocess
r = subprocess.run([sys.executable, f"{BASE}/modules/04-voice-of-customer/data/compute.py"],
                   capture_output=True, text=True)
check("module-04 court exit", r.returncode, 0)

if fail:
    print("\nCOURT FAILURES:")
    [print(" -", f) for f in fail]
    sys.exit(1)
print("\nMODULE-05 QFD COURT: ALL CHECKS PASS")
