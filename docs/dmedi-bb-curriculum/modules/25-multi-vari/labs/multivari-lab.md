# Lab — Multi-Vari Chart and Variance Components (Module 25)

Setup (curriculum root):

```bash
python3 modules/25-multi-vari/scripts/gen_multivari_bore.py   # seed 42501
python3 modules/25-multi-vari/scripts/derive_keys.py          # court, exit 0
```

Dataset: `data/multivari-bore.csv` — `obs, pc, spindle, time_block, bore_deviation_um`.

## Part 1 — Totals
1. n = 45; grand mean = 8.6198 um; SST = 2518.5487 (CENTERED); total s = 7.5657 um.
2. TSS witness: compute SUM(y^2) = 5862.074 and confirm it is not SST.
3. Spine check: total s sits in the 7.407 um regime (court band 6.9-7.9 um).

## Part 2 — Positional family by hand
4. Level means: PC1 -1.376, PC2 3.794, PC3 8.173, PC4 14.091, PC5 18.416.
5. SSB = SUM(m_l (mean_l - gm)^2) = 2243.543 (df 4); SSW = 275.005 (df 40).
6. MSB = 560.886, MSW = 6.875, F = 81.58, eta^2 = 0.8908.
7. Components: sigma2_family = (MSB - MSW)/9 = 61.5567; sigma2_within = 6.8751;
   share = 90.0%.

## Part 3 — Cyclical and temporal families
8. Spindle: means 8.537 / 8.108 / 9.214; SSB 9.327, MSB 4.664, MSW 59.743, F = 0.08.
9. Time block: means 8.067 / 8.409 / 9.383; SSB 13.972, MSB 6.986, MSW 59.633,
   F = 0.12.
10. Note: their MSW (~59.7) is the total variance minus the positional signal —
    they inherit everything positional explains. Their sigma2_family clamps at 0
    because MSB < MSW.

## Part 4 — ASCII family chart (draw before you compute)
11. Bar chart of pc means scaled to the range; compare the 19.79 um staircase of
    pc means against within-cell s = 2.62 um. If the staircase were noise, adjacent
    pc means would sit within ~2 s = 5.2 um of each other; here adjacent gaps run
    ~5 um and endpoint spread is ~7.5x s.

## Part 5 — Conclusion and decision
12. Rank family shares: positional 90.0%, cyclical 0.0%, temporal 0.0%.
13. Write the concentration decision: attack fixturing/positional variation first;
    spindle-to-spindle and drift-over-time are statistically indistinguishable
    (F < 3 for both).
14. Spine arithmetic: estimate Cpk today (mu = 12.009 + shifts per pc; use USL
    12.025) and the Cpk if the positional component were halved. Show your sum.
