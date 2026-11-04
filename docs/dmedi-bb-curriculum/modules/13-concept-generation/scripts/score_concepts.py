#!/usr/bin/env python3
"""Module 13 solution key: concept portfolio scoring (re-derive, never remember).
Score = 0.4*novelty + 0.6*feasibility. Input: datasets/concept-portfolio.csv
Seed registration: seed 1317 used only for the raw-idea funnel counts (workshop W3)."""
import csv, random
rows = list(csv.DictReader(open(__file__.rsplit("/scripts/",1)[0] + "/datasets/concept-portfolio.csv")))
ranked = sorted(rows, key=lambda r: -(0.4*int(r["novelty_1to5"]) + 0.6*int(r["feasibility_1to5"])))
for r in ranked:
    print(f"{r['concept_id']} {r['concept']:52s} S={0.4*int(r['novelty_1to5'])+0.6*int(r['feasibility_1to5']):.2f}")
random.seed(1317)  # raw-idea funnel: 12 raw ideas -> 4 affinity merges -> 8 concepts
