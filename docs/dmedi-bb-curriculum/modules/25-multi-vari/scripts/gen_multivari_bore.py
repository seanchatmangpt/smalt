#!/usr/bin/env python3
"""Lane 10: generate data/multivari-bore.csv (seed 42501).

CPPC multi-vari: 5 pcs x 3 spindles x 3 time blocks = 45 bore-deviation readings (um).
Families: POSITIONAL (pc), CYCLICAL (spindle), TEMPORAL (time block).
Planted signature: POSITIONAL dominates (pc offsets -10 / -5 / 0 / +5 / +10 um
about the baseline +9 um shift, i.e. mu = 12.009 mm per RUNNING-CASE.md);
spindle offsets 0, all time-block offsets 0, eps ~ N(0, 2.4 um).
pc offset population variance = (100+25+0+25+100)/5 = 50 um^2
-> total s = sqrt(50 + 5.76) ~ 7.47 um, the RUNNING-CASE 7.407um regime;
pc family explains 50/55.76 ~ 90%.
"""
import csv
import random

random.seed(42501)
BASE = 9.0
PC_OFFSETS = [-10.0, -5.0, 0.0, 5.0, 10.0]
SPINDLE_OFFSETS = [0.0, 0.0, 0.0]
TIME_OFFSETS = [0.0, 0.0, 0.0]
rows = []
for t_i, t in enumerate(["T1", "T2", "T3"]):
    for s_i, s in enumerate(["S1", "S2", "S3"]):
        for p_i in range(5):
            dev = BASE + PC_OFFSETS[p_i] + SPINDLE_OFFSETS[s_i] \
                + TIME_OFFSETS[t_i] + random.gauss(0, 2.4)
            rows.append((len(rows) + 1, f"PC{p_i+1}", s, t, round(dev, 2)))

with open("data/multivari-bore.csv", "w", newline="") as f:
    w = css = csv.writer(f)
    w.writerow(["obs", "pc", "spindle", "time_block", "bore_deviation_um"])
    w.writerows(rows)
print(f"wrote {len(rows)} rows")
