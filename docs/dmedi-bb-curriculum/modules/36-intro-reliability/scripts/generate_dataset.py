#!/usr/bin/env python3
"""Regenerates data/weibull-failure-times.csv byte-identically.

Seed: 42114 (registered in MANIFEST.md, owner Lane 14).
Law: inverse-CDF sampling of Weibull(beta=6.2417104095914056, eta=1290.6893420317635)
-- the (MTBF 1200 h, B10 900 h) spine pair's unique wear-out solution
(see slides-outline.md Slide 2). 40 draws.
"""
import math, random

BETA = 6.2417104095914056
ETA = 1290.6893420317635

random.seed(42114)
lines = ["unit_id,u_draw,hours\n"]
for i in range(1, 41):
    u = random.random()
    t = ETA * (-math.log(1 - u)) ** (1 / BETA)
    lines.append(f"{i},{u:.6f},{t:.1f}\n")

with open(__file__.replace("scripts/generate_dataset.py",
                           "data/weibull-failure-times.csv"), "w") as f:
    f.writelines(lines)
print("wrote 40 rows")
