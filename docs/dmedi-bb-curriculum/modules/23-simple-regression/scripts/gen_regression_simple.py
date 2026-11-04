#!/usr/bin/env python3
"""Lane 10: generate data/regression-simple.csv (seed 42301).

CPPC SR-71 gimbal housing: tool life (min) vs bore diameter deviation (um).
True law: dev = 1.6 + 0.42*life + eps, eps ~ N(0, 1.8 um), n=30.
"""
import csv
import random

random.seed(42301)
rows = []
for i in range(30):
    life = 10 + i * (80 - 10) / 29          # evenly spaced 10..80 min
    life += random.gauss(0, 2.5)            # jitter in tool life
    life = round(max(life, 2.0), 1)
    dev = 1.6 + 0.42 * life + random.gauss(0, 1.8)
    dev = round(dev, 2)
    rows.append((i + 1, life, dev))

with open("data/regression-simple.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["run", "tool_life_min", "bore_deviation_um"])
    w.writerows(rows)
print(f"wrote {len(rows)} rows")
