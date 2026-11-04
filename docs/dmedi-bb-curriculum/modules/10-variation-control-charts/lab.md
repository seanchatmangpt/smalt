# Module 10 Lab — Three Charts, Limits From the Data

Run from the curriculum root. Datasets: `data/xbar-r-subgroups.csv` (seed 42011,
+0.015 mm planted shift subgroups 18–20), `data/bore-baseline-100.csv` (seed 42008),
`data/lead-defectives.csv` (seed 42012). Minitab path given alongside; the python3
replication is the receipt. Full arithmetic in `solution-key.md`; automated check:
`python3 modules/10-variation-control-charts/courts/court.py` (exit 0 expected).

## Part 1 — X-bar/R (Minitab: Stat > Control Charts > Variables Charts > Xbar-R)

1. All observations in one column (`subgroup` as grouping) or 5 columns wide — both
   import; use the wide form of `data/xbar-r-subgroups.csv`.
2. Xbar-R Options > Estimate: default (R-bar). Options > Tests: perform all tests for
   the special causes selected in the lesson (T1/T2/T3/T5/T6).
3. Expected session output: Xbb 12.0116, R-bar 0.0191, UCL(X-bar) 12.0226,
   LCL(X-bar) 12.0006, UCL(R) 0.0404. Signals: subgroups 19, 20 (Test 1) and the
   Test-5 window ending at 21.
4. Phase I step: remove subgroups 18–20 from the limit estimation (Options > Estimate >
   "use the following subgroups" = 1–17, 21–25), recompute → Xbb 12.0097,
   UCL 12.0208, LCL 11.9986, R UCL 0.0406. Plot the original 25 points against the
   new limits: 18, 19, 20 all breach now.

## Part 2 — I-MR (Variables Charts > I-MR) on bore-baseline-100.csv

Expected: mean 12.0098, MR-bar 0.0077, I limits 12.0303/11.9893, MR UCL 0.02517.
Signals: obs 41 below LCL (Test 1); MR spikes at lags 10, 11, 23, 41; Test 6 cluster
ending at obs 12.

## Part 3 — p-chart (Attribute Charts > P) on lead-defectives.csv

1. Variables: `late_orders` as Defectives, `orders_inspected` as Sample size.
2. Expected: p-bar 0.1516; per-day UCL 0.250 (n=120), 0.259 (n=100), 0.272 (n=80).
   Breaches: day 17 (0.258) and day 18 (0.317). Day 19 (0.240, UCL 0.259) is elevated
   but in control — disposition via the physical timeline, not the chart alone.

## Part 4 — python3 replication (the receipt)

```bash
python3 modules/10-variation-control-charts/courts/court.py && echo COURT PASS
```

The court regenerates all three datasets byte-exact from their stated seeds, then
re-derives every limit, signal, and fraction above. Minitab's Test 2/3/5/6
implementations are the standard Nelson rules; the court implements the same
definitions over the same points, so fired-rule sets must agree.

## Gate

- [ ] X-bar/R limits + Phase I recompute reproduced; 18–20 dispositioned
- [ ] I-MR limits reproduced; obs 41 and MR spikes read with the gallery
- [ ] p-chart variable limits reproduced; days 17–18 named, day 19 dispositioned
- [ ] Court exits 0
