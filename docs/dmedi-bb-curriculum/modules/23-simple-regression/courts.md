# Module 23 Courts — exit-checked transcript

Command (from curriculum root): `python3 modules/23-simple-regression/scripts/derive_keys.py`

```text
TSS witness: centered SST=2456.2738 != uncentered sum(y^2)=15398.0608
n=30  xbar=45.2800  ybar=20.7700
Sxx=13380.9280  Sxy=5641.6760  Syy=2456.2738
b1=0.42162  b0=1.67902
yhat = 1.6790 + 0.4216 x
SSE=77.6265  SSR=2378.6473  SST=2456.2738  SSR+SSE=2456.2738
MSR=2378.6473 MSE=2.7724 s=1.66505
R2=0.96840  r=0.98407  adjR2=0.96727
se(b1)=0.01439  t=29.291  F=857.98  (sqrt(F)=29.291)
yhat(45)=20.6519  CI95=(20.0293,21.2746) width=1.2453
PI95 =(17.1856,24.1183) width=6.9328
p(slope)=0.000e+00   t_crit scipy=2.0484
COURT PASS: SST=SSR+SSE, sqrt(F)=|t|, t_crit=2.048, slope recovers 0.42
```

Exit code: 0.

Court assertions carried by the script:
1. SSR + SSE == SST (1e-6 relative) — the ANOVA identity, guarded against the
   uncentered-TSS bug by the printed witness (15398.06 vs 2456.27).
2. sqrt(F) == |t_slope| exactly.
3. t_crit(0.025, 28) = 2.048 verified against scipy when available.
4. Slope recovers the planted 0.42 within 0.06.

Data regenerable: `python3 modules/23-simple-regression/scripts/gen_regression_simple.py`
(seed 42301) -> `data/regression-simple.csv`, 30 rows.
