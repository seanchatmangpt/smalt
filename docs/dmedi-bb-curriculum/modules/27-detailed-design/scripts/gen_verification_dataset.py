#!/usr/bin/env python3
"""Module 27 verification dataset generator — DC-10 thermal warmup study.

Design-control action DC-10 (data/design-control-checklist.csv, row CP-13):
"Warmup protocol + thermal error model + offset; first-piece deviation <= 3 um
with model active". This script writes data/thermal-warmup-study.csv:
12 first-piece bore-deviation measurements (um from 12.000 mm nominal) WITHOUT
the warmup/offset model and 12 WITH it, python3 random seed 2711 (fixed, stated).

Usage: python3 scripts/gen_verification_dataset.py   (from module dir)
Exit 0 on success; the CSV is byte-reproducible from the seed.
"""
import csv, os, random

SEED = 2711
N = 12
WITHOUT_MEAN, WITHOUT_SD = 8.2, 2.0    # um deviation from nominal, model off
WITH_MEAN, WITH_SD = 2.2, 1.2          # um deviation, model active

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "data", "thermal-warmup-study.csv")

random.seed(SEED)
without = [round(random.gauss(WITHOUT_MEAN, WITHOUT_SD), 1) for _ in range(N)]
with_m = [round(random.gauss(WITH_MEAN, WITH_SD), 1) for _ in range(N)]

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["trial", "deviation_um_no_model", "deviation_um_with_model"])
    for i in range(N):
        w.writerow([i + 1, without[i], with_m[i]])
print(f"wrote {OUT}: {N} paired trials, seed {SEED}")
print("no-model:", without)
print("with-model:", with_m)
