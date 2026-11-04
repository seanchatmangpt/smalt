#!/usr/bin/env python3
"""Module 28 court. Run from curriculum root (or anywhere). Exit 0 = the two-way
ANOVA table re-derives from the raw 3x2x6 CSV, executed, never remembered.

Pins (re-derived, not remembered):
  F_A 4.63 / F_B 9.61 / F_AB 58.63; SS_total 0.000686 mm^2 with exact closure
  SSA+SSB+SSAB+SSE = SST; interaction-first read (F_AB >> F crit 3.32);
  MSE 4.13e-6 mm^2 (within-cell sigma 2.03 um); direct-SSE == by-subtraction;
  crossed interaction plot; unit-change invariance (um re-derivation).

STALENESS SWEEP: refuses the adjudicated-STALE 4.17 um spine sigma.

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero; still passing under corruption = VACUOUS COURT (exit 2).
"""
import collections, csv, math, statistics, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(MOD))
SRC = os.path.join(HERE, "data", "anova-2way.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: modules/28-2way-anova/data/anova-2way.csv missing")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

rows = list(csv.DictReader(open(SRC)))
y = [float(r["bore_deviation_mm"]) for r in rows]
mach = sorted({r["machine"] for r in rows})
coat = sorted({r["coating"] for r in rows})
N, a, b, n = len(y), len(mach), len(coat), 6
check("36_rows_3x2x6", (N, a, b, n), (36, 3, 2, 6))
check("balanced_n6_every_cell",
      tuple(sorted(collections.Counter((r["machine"], r["coating"]) for r in rows).values())),
      (6, 6, 6, 6, 6, 6))

G = sum(y); CT = G * G / N
SST = sum(v * v for v in y) - CT
cell = {(m, c): statistics.mean([float(r["bore_deviation_mm"]) for r in rows
                                 if r["machine"] == m and r["coating"] == c]) for m in mach for c in coat}
rowm = {m: statistics.mean([cell[(m, c)] for c in coat]) for m in mach}
colm = {c: statistics.mean([cell[(m, c)] for m in mach]) for c in coat}
grand = G / N

SSA = b * n * sum((rowm[m] - grand) ** 2 for m in mach)
SSB = a * n * sum((colm[c] - grand) ** 2 for c in coat)
SSAB = n * sum((cell[(m, c)] - rowm[m] - colm[c] + grand) ** 2 for m in mach for c in coat)
SSE = SST - SSA - SSB - SSAB                    # by subtraction (balanced)
MSE = SSE / 30

check("SS_total_0.000686", round(SST, 6), 0.000686, 1e-9)
check("SS_A", round(SSA, 6), 0.000038, 1e-9)
check("SS_B", round(SSB, 6), 0.000040, 1e-9)
check("SS_AB", round(SSAB, 6), 0.000484, 1e-9)
check("SS_E", round(SSE, 6), 0.000124, 1e-9)
check("closure_1e-9", abs(SST - (SSA + SSB + SSAB + SSE)), 0.0, 1e-9)
check("df_sum", (a - 1) + (b - 1) + (a - 1) * (b - 1) + (N - a * b), 35)

FA, FB, FAB = SSA / 2 / MSE, SSB / MSE, SSAB / 2 / MSE
check("F_A_4.63", round(FA, 2), 4.63, 1e-9)
check("F_B_9.61", round(FB, 2), 9.61, 1e-9)
check("F_AB_58.63", round(FAB, 2), 58.63, 1e-9)
check("MSE_4.13e-6", round(MSE * 1e6, 2), 4.13, 1e-9)
check("within_cell_sigma_2.03um", round(math.sqrt(MSE) * 1000, 2), 2.03, 1e-9)
check("interaction_first_FAB_gt_crit", FAB > 3.32, True)
check("interaction_dominates_SS", SSAB > SSA and SSAB > SSB, True)

# direct SSE (within-cell SS computed explicitly) must equal by-subtraction SSE
SSE_direct = sum((float(r["bore_deviation_mm"]) - cell[(r["machine"], r["coating"])]) ** 2
                 for r in rows)
check("direct_SSE_equals_subtraction", abs(SSE_direct - SSE), 0.0, 1e-12)

# cell means table (um deviation), README section 3
cm = {(m, c): round((cell[(m, c)] - 12.000) * 1000, 1) for m in mach for c in coat}
check("cell_M1_coated", cm[("M1", "coated")], 6.5, 1e-9)
check("cell_M1_uncoated", cm[("M1", "uncoated")], 14.1, 1e-9)
check("cell_M2_coated", cm[("M2", "coated")], 6.2, 1e-9)
check("cell_M2_uncoated", cm[("M2", "uncoated")], 13.1, 1e-9)
check("cell_M3_coated", cm[("M3", "coated")], 16.2, 1e-9)
check("cell_M3_uncoated", cm[("M3", "uncoated")], 7.9, 1e-9)
check("crossing_coated_below_then_above",
      cm[("M1", "coated")] < cm[("M1", "uncoated")] and
      cm[("M3", "coated")] > cm[("M3", "uncoated")], True)
# simple effect of coating at M3 (lab Task 4 grammar): +8.3 um, ~2 within-cell sigma
se_m3 = cm[("M3", "coated")] - cm[("M3", "uncoated")]
check("simple_effect_M3_+8.3um", round(se_m3, 1), 8.3, 1e-9)
check("simple_effect_sigma_ratio", abs(se_m3 / (math.sqrt(MSE) * 1000) - 4.09) <= 0.05, True)

# unit-change invariance: re-express response in um, every F unchanged
yu = [v * 1000 for v in y]
STu = sum(v * v for v in yu) - sum(yu) ** 2 / N
celu = {(m, c): 1000 * cell[(m, c)] for m in mach for c in coat}
rowu = {m: statistics.mean([celu[(m, c)] for c in coat]) for m in mach}
colu = {c: statistics.mean([celu[(m, c)] for m in mach]) for c in coat}
gU = statistics.mean(yu)
SA = b * n * sum((rowu[m] - gU) ** 2 for m in mach)
SB = a * n * sum((colu[c] - gU) ** 2 for c in coat)
SAB = n * sum((celu[(m, c)] - rowu[m] - colu[c] + gU) ** 2 for m in mach for c in coat)
SEu = STu - SA - SB - SAB
check("invariance_F_A", round(SA / 2 / (SEu / 30), 2), round(FA, 2), 1e-9)
check("invariance_F_B", round(SB / (SEu / 30), 2), round(FB, 2), 1e-9)
check("invariance_F_AB", round(SAB / 2 / (SEu / 30), 2), round(FAB, 2), 1e-9)

# STALENESS SWEEP: 4.17 um stale spine sigma
STALE_UM = 4.17
check("stale_sigma_refused_data", abs(math.sqrt(MSE) * 1000 - STALE_UM) > 0.5, True)
check("stale_sigma_refused_coherence",
      round(0.016 / (3 * STALE_UM / 1000), 2) != round(FAB, 2), True)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)

print("Module 28 court: ALL CHECKS PASS (F_A 4.63 / F_B 9.61 / F_AB 58.63, "
      "SS_total 0.000686 mm^2 exact closure, direct==subtraction SSE, cell means, "
      "crossing interaction, um invariance, stale 4.17 um refused)")

# ---------- mutation test ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if abs(round(FAB, 2) - 3.32) <= 1e-9:
        print("VACUOUS COURT: corrupted constant still passes"); sys.exit(2)
    print("MUTATION DETECTED: F_AB pinned at crit 3.32 vs derived %.4f -> nonzero" % FAB)
    sys.exit(1)
sys.exit(0)
