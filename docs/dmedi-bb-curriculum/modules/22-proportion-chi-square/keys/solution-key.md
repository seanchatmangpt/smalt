# Module 22 Solution Key — exercises E1-E6

All numbers are the verbatim output of an executed run of the derivation
script shipped at `keys/derive.py`, run from the curriculum root. Data:
scrap-shifts (seed 42194), cnc-ab (seed 42195), defect-machine (seed 42196),
bore-100-gof (seed 42197), all registered. The README tables must match
this output (they do).

## Executed receipt (verbatim, full run)

```
scrap: x=193 n=2500 phat=0.0772 np0=125 n(1-p0)=2375
z=6.240 zcrit_one=1.645 p_one=2.19e-10 p_two=4.37e-10
wald=(0.0667,0.0877) clopper=(0.0670,0.0884)
cnc: p3=25/320=0.0781 p4=30/310=0.0968 pbar=0.0873
z2=-0.829 p=0.407
diff=-0.0186 ci=(-0.0628,0.0255)
indep: chi2=23.389 df=6 p=0.00068 crit=12.592 min_exp=29.1
contrib scratch/CNC-1 = 0.41 (O=53, E=48.5)
contrib oversize/CNC-1 = 3.33 (O=43, E=32.6)
contrib porosity/CNC-2 = 3.24 (O=44, E=33.6)
contrib burrs/CNC-1 = 4.13 (O=38, E=52.8)
contrib burrs/CNC-3 = 3.48 (O=60, E=47.2)
row totals: [137  92 102 149] col totals: [170 158 152] N= 480
gof: n=100 xbar=12.0092 s=0.0042
cuts: 12.0044 12.0064 12.0079 12.0092 12.0106 12.0121 12.0141
obs: [12 11 13 15 13 13  9 14] chi2= 1.920 df=5 crit= 11.070 p= 0.860
```

## Answers

- **E1**: x = 193, n = 2500, p-hat = 0.0772; np0 = 125 >= 5 and
  n(1-p0) = 2375 >= 5 → normal approximation lawful. z = 6.240,
  zcrit(0.95) = 1.645 one-sided, p(one-sided) = 2.19e-10
  (two-sided 4.37e-10) → reject H0: p = 0.05; scrap runs near 7.7%, ~1.5x
  target. zcrit = 1.645 here vs 1.960 in M19/M20 because sidedness must
  match the declaration.
- **E2**: Wald (0.0667, 0.0877) vs Clopper-Pearson (0.0670, 0.0884): the
  exact interval is slightly wider and asymmetric; it exists because the
  Wald interval degrades at extreme p or small n (here n is large so the
  two nearly coincide).
- **E3**: p3 = 0.0781, p4 = 0.0968, p-bar = 0.0873; z = -0.829, |z| < 1.960,
  p = 0.407 → FAIL to reject. The unpooled 95% CI of the difference,
  (-0.0628, 0.0255), admits differences up to 6.3 points — failure to
  reject does NOT mean "the machines are equal"; the remedy is n, per the
  M19 power law.
- **E4**: E(scratch, CNC-1) = 137*170/480 = 48.5; min expected count 29.1
  >= 5, chi-square lawful, no pooling. chi2 = 23.389, df = 6, crit = 12.592,
  p = 0.00068 → reject H0 of independence: the defect mix depends on
  machine. Contributions: burrs/CNC-1 = 4.13 (O 38 vs E 52.8), oversize/
  CNC-1 = 3.33, porosity/CNC-2 = 3.24, burrs/CNC-3 = 3.48. Process read:
  machine-specific maintenance actions — CNC-1 → deburr path, CNC-2 →
  porosity (coolant/parameters), CNC-3 → burrs too.
- **E5**: x-bar = 12.0092, s = 0.0042; cuts at 12.0044 / 12.0064 / 12.0079 /
  12.0092 / 12.0106 / 12.0121 / 12.0141; observed 12/11/13/15/13/13/9/14;
  chi2 = 1.920, df = 5 (k-1-2: two parameters estimated — claiming df = 7
  is the classic lost-points error), crit = 11.070, p = 0.860 → fail to
  reject: no evidence against normality.
- **E6**: 1-prop z → Q1-B; 2-prop z → Q1-B two rates; chi-square
  independence → Q1-D; chi-square GOF → Q1-C. Exit rule: place all four
  from scenario text alone, no notes.

## Cross-check vs court.py pins

Every value matches the module 22 court pins exactly (z 6.240, p 4.37e-10,
Wald 0.0667/0.0877, CP 0.0670/0.0884; z2 -0.829 / p 0.407 / CI -0.0628,
0.0255; chi2 23.389, df 6, p 0.00068, contributions 4.13/3.33/3.24/3.48,
min-exp 29.1; GOF chi2 1.920, p 0.860, bin table). Zero drift findings.
