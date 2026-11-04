# Module 19 Solution Key — exercises E1-E6

All numbers below are the verbatim output of an executed run of the
derivation script shipped at `keys/derive.py` (same law as the parent
`key.md`), run from the curriculum root. Data: `data/bore-30.csv`
(seed 42190, registered in `datasets/MANIFEST.md`). Nothing is quoted from
README tables — the README tables must match this output (they do).

## Executed receipt (verbatim, full run)

```
n=30 xbar=12.0072 s=0.0035 se=0.000643
t=11.197 tcrit=2.045 p=4.782e-12  ci95=(12.0059,12.0085)
z(sigma known, 7.407um)=5.32 p=1.03e-07
z_a=1.9600 z_b=0.8416 n_raw=17.22 -> n=18
power(n=2) = 0.159
power(n=3) = 0.215
power(n=4) = 0.271
power(n=5) = 0.326
power(n=6) = 0.380
power(n=8) = 0.480
power(n=10) = 0.569
power(n=12) = 0.647
power(n=15) = 0.744
power(n=18) = 0.817
power(n=20) = 0.855
power(n=25) = 0.921
power(17)=0.795 power(18)=0.817
delta=2.0um n=18: power=0.209 beta=0.791
delta=2.0um n=30: power=0.316 beta=0.684
delta=2.0um n=50: power=0.480 beta=0.520
delta=3.0um n=18: power=0.405 beta=0.595
delta=3.0um n=30: power=0.602 beta=0.398
delta=3.0um n=50: power=0.817 beta=0.183
delta=5.0um n=18: power=0.817 beta=0.183
delta=5.0um n=30: power=0.959 beta=0.041
delta=5.0um n=50: power=0.998 beta=0.002
power(n=50, delta=2)=0.480
```

## Answers

- **E1**: H0: mu = 12.000 mm, H1: mu != 12.000 mm (parameters, not
  statistics), two-sided because off-target either way forces action
  (README §2 laws 1-4), alpha = 0.05 stated before computing. Computed:
  n = 30, x-bar = 12.0072 mm, s = 0.0035 mm, SE = 0.000643 mm, t = 11.197,
  tcrit(0.975, 29) = 2.045, p = 4.782e-12.
- **E2**: |t| = 11.197 > tcrit = 2.045 and p = 4.78e-12 < 0.05 → **reject
  H0**; CPPC consequence per README §3: re-master the spindle (~2 h + $900).
  "12.0072 is within ±25 um" is not a defense: 7 um is 0.95 sigma of process
  variation and the test says with near-certainty the center moved —
  statistical significance and in-spec are different questions.
- **E3**: sigma-known z (capability sigma 7.407 um): z = 5.32,
  p = 1.03e-07 — same decision as the t. Lawful when sigma comes from a
  large capability study; here s = 0.0035 < 0.007407, so t is the honest
  choice and z is the cross-check.
- **E4**: n_raw = 17.22 → n = 18; the power curve confirms power(17) = 0.795
  misses the 80% bar and power(18) = 0.817 clears it (first n with
  power >= 0.80).
- **E5**: the same n = 18 plan has beta = 0.791 against a 2 um drift —
  nearly blind; its 80% detection budget is spent entirely on the 5 um
  shift. Control-plan sample size must be set to the smallest shift with
  real consequence, not to whichever shift one convenient n detects.
- **E6**: 1-sample t → ONE-population path, Q3 sigma unknown; sigma-known z
  → ONE → Q3 sigma known (README §5a). Exit rule: no test without a tree
  path.

## Cross-check vs court.py pins

Every value above matches the module court pins exactly (t = 11.197,
tcrit = 2.045, p = 4.78e-12, z = 5.32, n_raw = 17.22, power(17) = 0.795,
power(18) = 0.817). Zero drift findings.
