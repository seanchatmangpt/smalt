#!/usr/bin/env python3
"""Pilot 30-day bore data, CPPC case. Owner lane 16.
Seed 42016, python3 random module, random.gauss.
Process: mu = 12.005 mm, sigma = 0.0045 mm (predicted Cpk ~1.48 vs USL side).
8 subgroups/day x n=5, 30 days. Ra: daily mean 0.80 um, sd 0.05 um.
"""
import random, csv, statistics
random.seed(42016)
rows=[]
for day in range(1,31):
    for sg in range(1,9):
        for k in range(1,6):
            bore=random.gauss(12.005,0.0045)
            rows.append([day,sg,k,round(bore,4)])
with open("pilot-bore-30day.csv","w",newline="") as f:
    w=csv.writer(f); w.writerow(["day","subgroup","obs","bore_mm"]); w.writerows(rows)
# daily Ra means (single daily Ra value per day, from surface finish checks)
ras=[round(random.gauss(0.80,0.05),3) for _ in range(30)]
with open("pilot-ra-daily.csv","w",newline="") as f:
    w=csv.writer(f); w.writerow(["day","ra_um"]); w.writerows(enumerate(ras,1))
print("bore rows",len(rows),"Ra days",len(ras))
