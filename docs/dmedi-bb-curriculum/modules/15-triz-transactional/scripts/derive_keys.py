#!/usr/bin/env python3
"""Module 15 solution keys. Claims sim seed 1507; onboarding durations seed 1511."""
import random, statistics, csv
# Case 1: 200 claims/mo, 6% defective claims, 25% sample + full trigger, 0.75 h/claim
random.seed(1507)
esc=[]
for _ in range(20000):
    claims=[random.random()<0.06 for _ in range(200)]
    if any(claims[:50]): audited=set(range(200))
    else: audited=set(range(50))
    esc.append(sum(1 for i in range(200) if claims[i] and i not in audited))
ph=1-0.94**50
print(f"escaped mean={statistics.mean(esc):.2f}/mo, P(zero escape)={esc.count(0)/20000:.3f}, P(trigger)={ph:.3f}")
print(f"expected audit h: 37.5+{ph:.3f}*112.5 = {37.5+ph*112.5:.1f} vs full 150.0")
# Case 2: onboarding from dataset
rows=list(csv.DictReader(open(__file__.rsplit("/scripts/",1)[0]+"/datasets/onboarding-durations.csv")))
ser=sorted(sum(float(r[k]) for k in ("legal_days","it_days","hr_days","quality_days","manager_days")) for r in rows)
par=sorted(max(float(r["legal_days"]),float(r["it_days"]))+max(float(r["hr_days"]),float(r["quality_days"]))+float(r["manager_days"]) for r in rows)
print(f"serial mean={statistics.mean(ser):.1f} p90={ser[10]:.1f}; parallel mean={statistics.mean(par):.1f} p90={par[10]:.1f}")
