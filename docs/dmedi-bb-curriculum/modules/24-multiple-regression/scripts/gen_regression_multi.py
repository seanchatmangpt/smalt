#!/usr/bin/env python3
"""Lane 10: generate data/regression-multi.csv (seed 42401).

CPPC surface finish: spindle speed (RPM), feed (mm/min), coolant temp (C) -> Ra (um).
True law: Ra = 2.10 - 0.00040*speed + 0.0180*feed + 0*temp + eps, eps ~ N(0, 0.06 um), n=36.
Plant: (a) speed/feed collinearity (feed rises with speed, r ~ +0.85);
       (b) coolant temp is pure noise -> insignificant, fuels the reduced-model F-test.
"""
import csv
import random

random.seed(42401)
rows = []
for i in range(36):
    speed = 8000 + 4000 * (i % 9) / 8 + random.gauss(0, 150)   # ~8000..12000
    base_feed = 120 + 120 * (i % 9) / 8                        # 120..240 tied to speed level
    feed = base_feed + random.gauss(0, 8)                      # collinear with speed
    temp = 20 + 20 * random.random()                           # independent noise, no effect
    ra = 2.10 - 0.00040 * speed + 0.0180 * feed + random.gauss(0, 0.06)
    rows.append((i + 1,
                 round(speed), round(feed, 1), round(temp, 1), round(ra, 3)))

with open("data/regression-multi.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["run", "spindle_speed_rpm", "feed_mm_min", "coolant_temp_c", "ra_um"])
    w.writerows(rows)
print(f"wrote {len(rows)} rows")
