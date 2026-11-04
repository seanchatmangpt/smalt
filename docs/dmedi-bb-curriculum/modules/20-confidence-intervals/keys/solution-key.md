# Module 20 Solution Key — exercises E1-E6

All numbers are the verbatim output of an executed run of the derivation
script shipped at `keys/derive.py`, run from the curriculum root. Data:
`data/bore-30.csv` (seed 42190) and `data/ci-trap-overlap.csv` (seed 42290),
both registered. The README tables must match this output (they do).

## Executed receipt (verbatim, full run)

```
bore-30: n=30 xbar=12.0072 s=0.0035 se=0.000643 tcrit=2.045
CI90=(12.0061, 12.0083)  width=0.0022 = 2*1.699*se
CI95=(12.0059, 12.0085)  width=0.0026 = 2*2.045*se
CI99=(12.0054, 12.0090)  width=0.0035 = 2*2.756*se
95% width=0.0026; halving needs ~4x n -> n~120 (width law 1/sqrt(n))
spindle1: m=12.0032 s=0.0013 ci=(12.0027,12.0036)
spindle2: m=12.0022 s=0.0023 ci=(12.0013,12.0030)
overlap=(12.0027,12.0030) width=0.0003 = 36% of narrower CI
pooled t=2.062 df=58 tcrit=2.002 p=0.0437
diff CI = (0.0000, 0.0019)
paired before: m=12.0074 ci=(12.0057,12.0091)
paired after:  m=12.0044 ci=(12.0027,12.0062)
paired t=-6.92 p=3.7e-07 diffCI=(-0.0039,-0.0021)
```

## Answers

- **E1**: 90/95/99% intervals = (12.0061, 12.0083), (12.0059, 12.0085),
  (12.0054, 12.0090). The entire 95% interval sits above 12.000 — the
  Module 19 rejection seen from the estimation side.
- **E2**: 95% width = 0.0026 mm; halving width needs ~4x n, so n ~ 120
  (width scales 1/sqrt(n)). s is process-owned; confidence level is
  consequence-owned — neither is a free knob.
- **E3**: spindle 1: x-bar = 12.0032, s = 0.0013, CI (12.0027, 12.0036);
  spindle 2: x-bar = 12.0022, s = 0.0023, CI (12.0013, 12.0030); overlap
  (12.0027, 12.0030) = 36% of the narrower CI — yet pooled t = 2.062,
  p = 0.0437 < 0.05 → REJECT. The trap verified: overlap AND rejection
  coexist; "overlapping CIs prove no difference" is dead.
- **E4**: the 95% CI of the difference is (0.0000, 0.0019) — excludes 0,
  agrees with the test. The difference CI (pooled/Welch/paired as the
  design dictates) is the lawful decider; marginal CIs answer a different
  question.
- **E5**: paired-feed marginal CIs before (12.0057, 12.0091) and after
  (12.0027, 12.0062) overlap heavily; paired t = -6.92, p = 3.7e-7,
  difference CI (-0.0039, -0.0021) excludes 0. Mechanism: pairing removes
  part-to-part variance from the comparison.
- **E6**: the seed is the replay key for every number in this key —
  `datasets/MANIFEST.md` ties dataset bytes to the stated seed, so a silent
  seed change after keys shipped would make every published number
  unreproducible; stating the seed before reporting is what makes the keys
  auditable (RUNNING-CASE data-provenance law).

## Cross-check vs court.py pins

Every value matches the module 20 court pins exactly (m1 12.0032 / s1
0.0013 / c1 (12.0027, 12.0036); m2 12.0022 / s2 0.0023 / c2 (12.0013,
12.0030); overlap 36%; t 2.062 / p 0.0437; diff CI hi 0.0019; bore-30 CI
table). Zero drift findings.
