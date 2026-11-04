# Module 24 Courts — exit-checked transcript

Command (from curriculum root): `python3 modules/24-multiple-regression/scripts/derive_keys.py`

```text
TSS witness: centered SST=2.4427 != uncentered sum(y^2)=67.3714
== full model ==
Intercept    b= 2.230559  se=0.156231  t= 14.277  p=1.977e-15
speed        b=-0.000405  se=0.000033  t=-12.192  p=1.44e-13
feed         b= 0.018042  se=0.001063  t= 16.970  p=1.472e-17
coolant_temp b=-0.002774  se=0.001615  t=-1.718  p=0.09554
SST=2.4427 SSR=2.3542 SSE=0.0886  R2=0.96374 adjR2=0.96034
F(3,32)=283.47  p=4.061e-23  s=0.0526 um

== standardized betas (ranking) ==
speed        beta*=-2.0567
feed         beta*= 2.8841
coolant_temp beta*=-0.0605

== VIF (auxiliary regressions, same hand-rolled solver) ==
speed        R2aux=0.9602  tolerance=0.0398  VIF=25.109
feed         R2aux=0.9608  tolerance=0.0392  VIF=25.487
coolant_temp R2aux=0.0856  tolerance=0.9144  VIF=1.094

== residual analysis ==
Shapiro-Wilk W=0.9562 p=0.1642  -> normality OK
Breusch-Pagan LM=0.613 (chi2, df=3) p=0.8934  -> homoscedastic OK
Durbin-Watson DW=2.2406  -> autocorrelation none

== reduced-model F-test (drop coolant_temp_c) ==
SSE_reduced=0.0968  SSE_full=0.0886
F = ((SSE_r - SSE_f)/1) / (SSE_f/32) = 2.950  p=0.0955
partial t for coolant = -1.718;  sqrt(F) = 1.718 (must match |t|)

COURT PASS: SST identity, sqrt(F)=|t_partial|, coolant insignificant,
residuals clean, planted coefficients recovered
```

Exit code: 0.

Court assertions carried by the script:
1. TSS witness: centered SST distinguished from uncentered sum(y^2) (relative
   margin > 5%).
2. SSR + SSE == SST (1e-6 relative).
3. sqrt(F_drop) == |t_coolant| to 1e-6 (reduced-model identity).
4. coolant_temp p > 0.05 (planted insignificance, fuels the exercise).
5. Residual court: Shapiro p > 0.05, BP p > 0.05, DW in (1.5, 2.5).
6. Planted coefficients recovered: feed 0.018 +/- 0.004, speed -0.0004 +/- 0.0002.

Data regenerable: `python3 modules/24-multiple-regression/scripts/gen_regression_multi.py`
(seed 42401) -> `data/regression-multi.csv`, 36 rows.
