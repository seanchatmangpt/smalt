#!/usr/bin/env python3
"""Module 16 dataset generator -- CPPC bore-finish route concept trials.

Synthetic 30-piece pilot trials for each of the 4 candidate bore-finish
routes, used to ground the Pugh scores and the AHP pairwise judgments.
Seed is stated (data provenance law, RUNNING-CASE.md). Re-running with the
same seed reproduces the committed CSV byte-for-byte.

ADJUDICATED 2026-11-04: concept A is pinned to the RUNNING-CASE baseline
pair (mu = 12.009 mm, sigma = 7.407 um -> Cpk = 0.72). The pre-adjudication
version of this generator used sigma = 4.17 um for A; that pair computes
Cpk ~ 1.28 and contradicts the pinned 0.72. Any artifact derived from the
old CSV is stale.
"""
import csv
import os
import random

SEED = 1607  # module 16, lane 07
N_PER_CONCEPT = 30

# (concept, true mean mm, true sigma mm) -- A pinned to the RUNNING-CASE
# baseline (Cpk = 0.72, mu = 12.009, sigma = 7.407 um). Others authored so
# that pilot Cpk estimates land in distinct bands per concept:
#   A ~0.72 (incumbent, not capable), B ~1.47, C ~1.17, D ~1.60
TRUTH = [
    ("A-citizen-regrind", 12.009, 0.007407),
    ("B-peck-deep-drill-then-bore", 12.003, 0.00500),
    ("C-helical-interpolation", 12.004, 0.00600),
    ("D-combined-rough-plus-finish-boring-bar", 12.001, 0.00500),
]

LSL, USL = 11.975, 12.025  # CTQ-1 spec 12.000 +/- 0.025 mm


def cpk(mu, sigma):
    return min(USL - mu, mu - LSL) / (3 * sigma)


def main():
    rng = random.Random(SEED)
    rows = []
    for concept, mu, sigma in TRUTH:
        for i in range(1, N_PER_CONCEPT + 1):
            bore = rng.gauss(mu, sigma)
            # Ra coupled to process signature: scatter around a route-typical
            # center, correlated with bore error so the CSV is coherent.
            ra_center = {
                "A-citizen-regrind": 1.6,
                "B-peck-deep-drill-then-bore": 1.3,
                "C-helical-interpolation": 2.1,
                "D-combined-rough-plus-finish-boring-bar": 0.9,
            }[concept]
            ra = max(0.1, rng.gauss(ra_center + 0.25 * (bore - mu) * 100, 0.18))
            rows.append([concept, i, f"{bore:.4f}", f"{ra:.3f}"])

    # module-dir invocation convention (court.md): anchor to this script's
    # location so the court passes regardless of caller cwd
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "data", "concept_trials.csv")
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["concept", "piece", "bore_mm", "ra_um"])
        w.writerows(rows)
    print(f"wrote {path}: {len(rows)} rows, seed {SEED}, n={N_PER_CONCEPT}/concept")
    for concept, mu, sigma in TRUTH:
        print(f"  {concept}: authored Cpk = {cpk(mu, sigma):.3f}")


if __name__ == "__main__":
    main()
