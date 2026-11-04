#!/usr/bin/env python3
"""Module 38 solution key — conjoint analysis on the CPPC machining-service offer.
Full-profile card design on an L9 orthogonal array (4 attributes x 3 levels),
one respondent's rank ordering of the 9 cards (seed 38001), part-worth utilities
estimated by OLS with effect coding, attribute importance = range share.

Regenerates conjoint-cards.csv + conjoint-ranks.csv (deterministic) and
re-derives every printed number from the CSVs on disk.
"""
import csv, itertools, random

SEED = 38001
BASE = __file__.rsplit("/", 1)[0]

ATTRS = {
    "price":   ["$52.00", "$38.00", "$30.00"],   # per unit
    "lead":    ["15 days", "10 days", "7 days"],
    "tol":     ["+/-0.025 mm", "+/-0.015 mm", "+/-0.008 mm"],
    "finish":  ["Ra 1.6", "Ra 0.8", "Ra 0.4"],
}
KEYS = ["price", "lead", "tol", "finish"]

# ------------------------------------------------- L9 orthogonal array (3^4)
L9 = [(0, 0, 0, 0), (0, 1, 1, 2), (0, 2, 2, 1),
      (1, 0, 1, 1), (1, 1, 2, 0), (1, 2, 0, 2),
      (2, 0, 2, 2), (2, 1, 0, 1), (2, 2, 1, 0)]

def generate():
    random.seed(SEED)
    # True respondent part-worths (utility units, arbitrary scale).
    # Price is coded low index = expensive; we make cheap = good.
    true_pw = {
        "price":  [-2.0, 1.2, 2.4],   # by level index 0,1,2
        "lead":   [-1.0, 0.4, 1.6],
        "tol":    [-0.6, 0.2, 0.9],   # tighter tolerance valued
        "finish": [-0.3, 0.1, 0.5],
    }
    with open(f"{BASE}/conjoint-cards.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["card", "price", "lead", "tol", "finish"] +
                   ["u_price", "u_lead", "u_tol", "u_finish", "u_total"])
        for card, idx in enumerate(L9, 1):
            levels = dict(zip(KEYS, idx))
            u = sum(true_pw[k][i] for k, i in levels.items())
            w.writerow([card] + [ATTRS[k][i] for k, i in levels.items()] +
                       [true_pw["price"][idx[0]], true_pw["lead"][idx[1]],
                        true_pw["tol"][idx[2]], true_pw["finish"][idx[3]],
                        round(u, 3)])
    # Respondent ranks cards by true utility + gaussian noise; 1 = most preferred.
    us = [sum(true_pw[k][i] for k, i in zip(KEYS, idx)) for idx in L9]
    noisy = [u + random.gauss(0, 0.55) for u in us]
    order = sorted(range(9), key=lambda i: -noisy[i])
    ranks = [0] * 9
    for rank, card_i in enumerate(order, 1):
        ranks[card_i] = rank
    with open(f"{BASE}/conjoint-ranks.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["card", "rank_1_most_preferred"])
        for card, r in enumerate(ranks, 1):
            w.writerow([card, r])

generate()

# ---------------------------------------------------------------- analysis
cards = list(csv.DictReader(open(f"{BASE}/conjoint-cards.csv")))
ranks = {int(r["card"]): int(r["rank_1_most_preferred"])
         for r in csv.DictReader(open(f"{BASE}/conjoint-ranks.csv"))}

# OLS with effect coding: for each attribute, 2 dummy columns (level vs mean of
# the OTHER two levels); level 2 column = -(c0 + c1). Solve normal equations
# with plain gaussian elimination (stdlib only).
def build_X():
    rowsX, yv = [], []
    for c in cards:
        k = int(c["card"])
        row = [1.0]
        for a in KEYS:
            lvl = ATTRS[a].index(c[a])
            d0 = 1.0 if lvl == 0 else (-1.0 if lvl == 2 else 0.0)
            d1 = 1.0 if lvl == 1 else (-1.0 if lvl == 2 else 0.0)
            row += [d0, d1]
        rowsX.append(row)
        yv.append(float(ranks[k]))
    return rowsX, yv

def solve_ols(X, y):
    p = len(X[0])
    XtX = [[sum(X[i][a] * X[i][b] for i in range(len(X))) for b in range(p)]
           for a in range(p)]
    Xty = [sum(X[i][a] * y[i] for i in range(len(X))) for a in range(p)]
    # augment + gaussian elimination with partial pivoting
    A = [XtX[i] + [Xty[i]] for i in range(p)]
    for col in range(p):
        piv = max(range(col, p), key=lambda r: abs(A[r][col]))
        A[col], A[piv] = A[piv], A[col]
        for r in range(p):
            if r != col and A[col][col] != 0:
                f = A[r][col] / A[col][col]
                A[r] = [A[r][c] - f * A[col][c] for c in range(p + 1)]
    return [A[i][p] / A[i][i] for i in range(p)]

b = solve_ols(*build_X())
print("== Module 38 solution key: conjoint part-worths via OLS (rank regression) ==")
print("effect coding, dependent variable = card rank (1 = most preferred;")
print("negative coefficients therefore indicate preferred levels)")
print(f"\nintercept b0 (mean rank) = {b[0]:.3f}")
names = []
for a in KEYS:
    for j, suffix in enumerate(("lvl0", "lvl1")):
        names.append(f"{a}:{suffix}")
for nm, v in zip(names, b[1:]):
    print(f"  b({nm:<12}) = {v:+.3f}")

# part-worths per attribute level (u_level2 = -(u0 + u1))
pw = {}
for ai, a in enumerate(KEYS):
    u0, u1 = b[1 + 2 * ai], b[2 + 2 * ai]
    pw[a] = [u0, u1, -(u0 + u1)]
print("\n-- part-worth utility table (rank scale; more negative = more preferred) --")
for a in KEYS:
    vals = ", ".join(f"{ATTRS[a][i]}: {pw[a][i]:+.3f}" for i in range(3))
    print(f"  {a:<7} {vals}")

# attribute importance = range share (on rank scale, sign irrelevant)
ranges = {a: max(pw[a]) - min(pw[a]) for a in KEYS}
tot = sum(ranges.values())
print("\n-- attribute importance (range share) --")
for a in KEYS:
    print(f"  {a:<7} range = {ranges[a]:.3f}  importance = {100 * ranges[a] / tot:5.1f}%")

# total utility of every possible combination (3^4 = 81), best/worst
combos = []
for lv in itertools.product(range(3), repeat=4):
    u = sum(pw[a][i] for a, i in zip(KEYS, lv))
    combos.append((u, lv))
combos.sort()
print("\n-- predicted best / worst profiles (of all 81) --")
# rank 1 = most preferred, so LOWEST predicted rank value = BEST
best, worst = combos[0], combos[-1]
for label, (u, lv) in (("BEST (predicted rank 1)", best),
                       ("WORST (predicted rank 9)", worst)):
    desc = ", ".join(f"{a}={ATTRS[a][i]}" for a, i in zip(KEYS, lv))
    print(f"  {label}: u = {u:+.3f}  [{desc}]")
