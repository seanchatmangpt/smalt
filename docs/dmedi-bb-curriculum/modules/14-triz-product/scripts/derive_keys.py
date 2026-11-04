#!/usr/bin/env python3
"""Module 14 solution keys. Ground truth = datasets/tool-wear.csv (synthetic, seed 1419,
diameter_drift_um rounded to 0.01 um). Keys re-derive from the CSV, never from memory."""
import csv, statistics
d=[(float(r["parts_since_tool_change"]), float(r["diameter_drift_um"]))
   for r in csv.DictReader(open(__file__.rsplit("/scripts/",1)[0]+"/datasets/tool-wear.csv"))]
xs=[x for x,_ in d]; ys=[y for _,y in d]
mx=statistics.mean(xs); my=statistics.mean(ys)
sxx=sum((x-mx)**2 for x in xs); sxy=sum((x-mx)*(y-my) for x,y in zip(xs,ys))
slope=sxy/sxx; intercept=my-slope*mx
resid=[y-(intercept+slope*x) for x,y in d]
sres=(sum(r*r for r in resid)/38)**0.5
print(f"slope={slope:.4f} um/part ({slope*100:.2f} um/100 parts), intercept={intercept:.4f} um, s_res={sres:.2f} um")
print(f"predicted drift at 500 parts={slope*500:.2f} um; uncompensated lag per 100-part comp interval={slope*100:.2f} um")
print(f"bores/shift: 480/7.5={480/7.5:.0f}, 480/6.4={480/6.4:.0f}, gain={480/6.4-480/7.5:.1f} ({(7.5-6.4)/7.5*100:.1f}%)")
