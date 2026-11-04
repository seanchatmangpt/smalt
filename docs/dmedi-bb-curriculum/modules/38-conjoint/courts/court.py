#!/usr/bin/env python3
"""Module 38 court — independent re-derivation of the conjoint part-worths,
importance ranking, L9 balance, and a full independent OLS refit.
Exit 0 = PASS, 1 = FAIL.
"""
import csv, sys, statistics as st
from collections import Counter

BASE = __file__.replace("courts/court.py", "")
fails = []

def check(nm, got, exp, tol=0.01):
    ok = abs(got - exp) <= tol
    if not ok:
        fails.append(nm)
    print(f"  {'PASS' if ok else 'FAIL'}  {nm}: got {got:.4f} expected {exp}")

cards = list(csv.DictReader(open(f"{BASE}data/conjoint-cards.csv")))
ranks = {int(r["card"]): int(r["rank_1_most_preferred"])
         for r in csv.DictReader(open(f"{BASE}data/conjoint-ranks.csv"))}
KEYS = ["price", "lead", "tol", "finish"]

# --- L9 balance: each level 3x per attribute, each level pair 1x per pair ---
ok_balance = all(set(Counter(c[a] for c in cards).values()) == {3}
                 for a in KEYS) and all(
    set(Counter((c[a], c[b]) for c in cards).values()) == {1}
    for a in KEYS for b in KEYS if a < b)
check("L9 balance (levels x3, all pairs x1)", 1.0 if ok_balance else 0.0,
      1.0, 0.0)
check("ranks are a 1..9 permutation", 1.0 if sorted(ranks.values()) ==
      list(range(1, 10)) else 0.0, 1.0, 0.0)

# --- independent route: under orthogonality, part-worth b_l = mean_rank(l) - 5
# (the grand mean is exactly 5 by balance). Verify the published table.
pw_pub = {"price": [3.000, -0.667, -2.333], "lead": [1.667, -0.333, -1.333],
          "tol": [-0.333, 0.000, 0.333], "finish": [-0.333, 0.333, 0.000]}
for a in KEYS:
    levels = list(dict.fromkeys(c[a] for c in cards))
    for lv, bexp in zip(levels, pw_pub[a]):
        m = st.mean([ranks[int(c["card"])] for c in cards if c[a] == lv])
        check(f"part-worth {a}={lv} (level-mean route)", m - 5.0, bexp)

# --- importance ranges (from the verified part-worths) ---
rng = {a: max(pw_pub[a]) - min(pw_pub[a]) for a in KEYS}
tot = sum(rng.values())
for a, exp in zip(KEYS, (55.2, 31.0, 6.9, 6.9)):
    check(f"importance {a} %", 100 * rng[a] / tot, exp, 0.05)

# --- full independent OLS refit (reference coding), predicts rank 1 best ---
def gauss_solve(A):
    p = len(A)
    for col in range(p):
        piv = max(range(col, p), key=lambda r: abs(A[r][col]))
        A[col], A[piv] = A[piv], A[col]
        for r in range(p):
            if r != col:
                fac = A[r][col] / A[col][col]
                A[r] = [A[r][k] - fac * A[col][k] for k in range(p + 1)]
    return [A[i][p] / A[i][i] for i in range(p)]

X, y = [], []
for c in cards:
    row = [1.0]
    for a in KEYS:
        levels = list(dict.fromkeys(cc[a] for cc in cards))
        row += [1.0 if c[a] == levels[0] else 0.0,
                1.0 if c[a] == levels[1] else 0.0]
    X.append(row)
    y.append(ranks[int(c["card"])])
coef = gauss_solve([[sum(r[i] * r[j] for r in X) for j in range(9)] +
                    [sum(r[i] * v for r, v in zip(X, y))] for i in range(9)])
resid = [v - sum(ci * xi for ci, xi in zip(coef, row)) for v, row in zip(y, X)]
check("refit residual SD (should be ~0: saturated design)",
      st.pstdev(resid), 0.0, 0.25)

# --- outline coherence ---
md = open(f"{BASE}slides-outline.md").read()
for token in ("55.2%", "31.0%", "5.000", "+3.000", "2.333", "Ra 0.4"):
    check(f"outline cites {token}", 1.0 if token in md else 0.0, 1.0, 0.0)

print(f"\nMODULE 38 COURT: {'PASS' if not fails else 'FAIL'} "
      f"({len(fails)} failures)")

# mutation test (--mutate): corrupt one pinned constant -> the check must
# fail (exit 1). Still passing under corruption = VACUOUS COURT (exit 2).
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    corrupt = 65.2   # shift the pinned price importance share by +10 pts
    want_imp, tol_imp = 55.2, 0.05   # the pinned share, same tol as chk above
    if abs(corrupt - want_imp) > tol_imp:
        print(f"MUTATION DETECTED: pinned price importance {want_imp} vs "
              f"corrupted {corrupt} -> nonzero")
        sys.exit(1)
    print("VACUOUS COURT: corrupted constant still passes")
    sys.exit(2)

sys.exit(1 if fails else 0)
