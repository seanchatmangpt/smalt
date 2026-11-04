#!/usr/bin/env python3
"""Pilot daily production and scrap, CPPC case. Owner lane 16.
Seed 42016 (separate stream from gen_pilot.py), python3 random module.
30 days x 150 pieces/day production; scrap ~ Bernoulli p=0.0008 per piece
(bore-related ~9 ppm at Cpk 1.48 + non-bore ops), tracked at 100% final check.
"""
import random, csv
random.seed(42016)
rows=[]
for day in range(1,31):
    prod=150
    scrap=sum(1 for _ in range(prod) if random.random()<0.0008)
    rows.append([day,prod,scrap])
with open("pilot-scrap-daily.csv","w",newline="") as f:
    w=csv.writer(f); w.writerow(["day","produced","scrap"]); w.writerows(rows)
print("scrap days",len(rows))
