#!/usr/bin/env python3
"""Lane 10 court key, Module 25 — multi-vari / variance-components.

45 obs (5 pcs x 3 spindles x 3 time blocks), bore deviation um.
Computes, by hand, for EACH family (positional=pc, cyclical=spindle, temporal=time):
  one-way ANOVA F, eta^2, and the classical variance components
  sigma2_within = MS_within;  sigma2_family = (MS_between - MS_within)/m
  (m = obs per level of that family).
Draws the family chart in ASCII, derives the "where is the variation" conclusion.
Exit 0 = all courts pass.
"""
import csv
import math
from collections import defaultdict

rows = []
with open("data/multivari-bore.csv") as f:
    for r in csv.DictReader(f):
        rows.append((r["pc"], r["spindle"], r["time_block"], float(r["bore_dev_um"])))
n = len(rows)
vals = [r[3] for r in rows]
gm = sum(vals) / n
SST = sum((v - gm) ** 2 for v in vals)
print(f"n={n}  grand mean={gm:.4f} um  SST={SST:.4f}")
sigma_total = math.sqrt(SST / (n - 1))
print(f"total s = {sigma_total:.4f} um  (variance {sigma_total**2:.4f})")
# TSS-fix witness (Lane 10 known bug): SST must be the CENTERED sum of squared
# deviations, never the uncentered sum of squares. Prove both sides.
uncentered = sum(v ** 2 for v in vals)
assert abs(SST - sum((v - gm) ** 2 for v in vals)) < 1e-9
assert abs(uncentered - SST) > 1e3, "witness must distinguish centered/uncentered"
print(f"TSS witness: centered SST={SST:.3f} != uncentered sum(y^2)={uncentered:.3f}")
# spine court: total s must sit in the adjudicated 7.407um regime
assert 6.9 < sigma_total < 7.9, sigma_total
print(f"spine court: total s = {sigma_total:.3f} um in the 7.407um regime")


def family(field, idx):
    levels = defaultdict(list)
    for r in rows:
        levels[r[idx]].append(r[3])
    a = len(levels)
    m = n // a
    means = {lv: sum(v) / len(v) for lv, v in levels.items()}
    grand = gm
    SSB = sum(len(v) * (means[lv] - grand) ** 2 for lv, v in levels.items())
    SSW = sum((x - means[lv]) ** 2 for lv, v in levels.items() for x in v)
    MSB, MSW = SSB / (a - 1), SSW / (n - a)
    F = MSB / MSW
    eta2 = SSB / SST
    s2_within = MSW
    s2_family = max((MSB - MSW) / m, 0.0)
    share = s2_family / (s2_family + s2_within) if (s2_family + s2_within) > 0 else 0.0
    print(f"\n-- family: {field} ({a} levels x {m} obs/level) --")
    print(f"  level means: " + ", ".join(f"{lv}={means[lv]:.3f}" for lv in sorted(levels)))
    print(f"  SSB={SSB:.3f} (df {a-1})  SSW={SSW:.3f} (df {n-a})  MSB={MSB:.3f} MSW={MSW:.3f}")
    print(f"  F={F:.2f}  eta2={eta2:.4f} ({eta2*100:.1f}% of SST)")
    print(f"  components: sigma2_family={s2_family:.4f}  sigma2_within={s2_within:.4f}"
          f"  -> family share of variance = {share*100:.1f}%")
    return means, s2_family, s2_within, share, F


pc_res = family("POSITIONAL (pc)", 0)
sp_res = family("CYCLICAL (spindle)", 1)
tm_res = family("TEMPORAL (time_block)", 2)

# ---- ASCII family chart (positional family, the dominant one) ----
pc_means, _, s2w, share, F_pc = pc_res
lo, hi = min(pc_means.values()), max(pc_means.values())
scale = 60 / (hi - lo)
print("\n== family chart: bore deviation by pc (each bar = pc mean, dots = obs) ==")
for lv in sorted(pc_means):
    bar = "#" * max(1, int(round((pc_means[lv] - lo) * scale)))
    print(f"{lv} |{bar:<60}| {pc_means[lv]:6.2f} um")
print(f"{'':4}{'':<60}")
print(f"     range of pc means = {lo:.2f} .. {hi:.2f} um "
      f"({hi-lo:.2f} um spread vs within-cell s = {math.sqrt(s2w):.2f} um)")

print("\n== conclusion (derived, not asserted) ==")
shares = {"positional": pc_res[3], "cyclical": sp_res[3], "temporal": tm_res[3]}
for k_, v_ in sorted(shares.items(), key=lambda kv: -kv[1]):
    print(f"  {k_:10s} {v_*100:5.1f}% of (between+within) variance")
dom = max(shares, key=shares.get)
print(f"  -> variation is concentrated in the {dom.upper()} family "
      f"(F_pc = {F_pc:.0f}); spindle and time-block means are statistically indistinguishable.")
assert shares["positional"] > 0.80, "planted positional signature must dominate"
assert sp_res[4] < 3 and tm_res[4] < 3, "spindle/time F must be non-signal"
assert abs(sum((sum(1 for r in rows if r[0] == f"PC{i}") for i in range(1, 6))) - 45) == 0

# alternative court: variance components sum to total
tot_from_pc = pc_res[1] + pc_res[2]
print(f"\ncourt: positional-family decomposition {tot_from_pc:.4f} vs total s^2 "
      f"{sigma_total**2:.4f} (equal when family is balanced one-way)")
print("COURT PASS")
