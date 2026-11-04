# Lane 15 Receipt — Modules 37–41 (Curvature, Conjoint, Mixtures, Robust Design, Helicopter RSM Lab)

Standing: **ALIVE** — all five courts executed this session, exit 0, real output below.

## Subject

`/Users/sac/smalt/docs/dmedi-bb-curriculum/` — Lane 15 owned surfaces only:
`modules/37-doe-curvature/`, `modules/38-conjoint/`, `modules/39-mixture-designs/`,
`modules/40-robust-design/`, `modules/41-helicopter-rsm-lab/`, MANIFEST rows
(6 dataset rows, appended at MANIFEST.md line 42).

## Delivered (verified on disk)

Per module: `slides-outline.md` (all numbers embedded from key output), `data/compute.py` (seed-stated python3-stdlib solution key that regenerates the dataset and re-derives every published number), `courts/court.py` (independent-re-derivation court, exit 0/1), `data/*.csv`. Module 41 additionally carries the full run-sheet spec and sequential-design teaching notes in its outline.

## Courts (actual exits)

```
python3 modules/37-doe-curvature/courts/court.py   -> EXIT 0 (20 checks PASS)
python3 modules/38-conjoint/courts/court.py        -> EXIT 0 (26 checks PASS)
python3 modules/39-mixture-designs/courts/court.py -> EXIT 0 (26 checks PASS)
python3 modules/40-robust-design/courts/court.py   -> EXIT 0 (43 checks PASS)
python3 modules/41-helicopter-rsm-lab/courts/court.py -> EXIT 0 (43 checks PASS)
```

## Key derived results (all re-derived by courts, not asserted)

- M37: curvature t = 4.223 (df 20, crit 2.131) fires; corner 11.590 µm vs center 5.390 µm, diff +6.200 µm; effects E(A) −4.450, E(B) +2.255, E(C) +0.665, E(AB) +1.600; axial unit step (+0.884, −0.448, −0.132).
- M38: part-worths verified via the orthogonality identity mean-rank(level) − 5 = part-worth (independent of the key's effect-coded OLS): price +3.000/−0.667/−2.333, lead +1.667/−0.333/−1.333, tol ±0.333, finish ±0.333; importances 55.2 / 31.0 / 6.9 / 6.9%; L9 balance (levels ×3, all 6 pairs ×1) proven; independent refit residual 0.
- M39: Scheffé quadratic b1 12.85, b2 7.01, b3 2.71, b12 +15.99 (synergy), b13 −9.53 (antagonism), b23 −0.34; OLS cross-check agrees; centroid predicted 8.20 vs observed 8.21; optimum oil 0.70/emulsifier 0.30/water 0.00 → 14.45 min; sum-to-1 proven on all 14 rows.
- M40: all 8 runs' mean + S/N_STB + S/N_LTB re-derived (run 6 V9000/F220/coated: mean 3.23 µm, S/N −10.26 dB, best); effects speed +3.23 / feed −2.24 / coating +4.25 dB; coating×hardness noise lift +0.84 µm uncoated vs −0.41 µm coated (robustness lever witnessed); run-6 raw outer deviations [3.61, 3.70, 2.83, 2.78] re-checked exactly.
- M41: screen coefs 0.906/0.496/−0.301 (effects ×2 re-derived via contrast route on regenerated alias structure E=ACD, F=ABC, G=BCD); CCD (α=2, 19 runs) quadratic recovered within 0.005 of the key on all 10 coefficients; stationary point (+1.100, +0.579, −0.655) → 4.922 s predicted, 4.95 s confirmed (drops [4.94, 4.98, 4.95]); +1.95 s over screening grand mean 3.00 s; 39 CSV rows + flown confirmation = 40 runs.

## Court catches during authoring (caught by courts/key runs, not by pre-reading)

1. M38: initial key labeled the predicted-best profile "WORST" — rank-scale direction trap caught when the "best" profile printed expensive/slow; fixed to rank-1-lowest-utility law and documented as a slide.
2. M39: court's sum-to-1 check first failed at 1e-9 tolerance on 4-dp CSV rounding (3 × 0.3333 = 0.9999) — tolerance reset to rounding scale; constraint law documented with its rounding caveat.
3. M40: outline cited unicode-minus "−16.72" while the court greps ASCII — token normalized.
4. M41: the key labeled OLS coefficients as "effects" (they are effect/2); caught by the court's contrast route producing 2× the published numbers; relabeled `coef … (effect = 2×coef)` in key and outline. Also: the court's first 40-row expectation failed (confirmation is flown, not stored) — expectation corrected to 39 CSV rows.

## Falsifiers (open, by design)

- M37 lab item 6 and M40 lab item 4/5 and M41 lab steps 3/5 are candidate-executed
  courts (hand derivations, constrained re-searches, own-helicopter arcs) — no canned
  answers; the modules would be vacuous with them pre-answered.
