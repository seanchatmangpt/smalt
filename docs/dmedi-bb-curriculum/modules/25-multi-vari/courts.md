# Module 25 Courts — exit-checked transcript

Command (from curriculum root): `python3 modules/25-multi-vari/scripts/derive_keys.py`

```text
n=45  grand mean=8.6198 um  SST=2518.5487
total s = 7.5657 um  (variance 57.2397)
TSS witness: centered SST=2518.549 != uncentered sum(y^2)=5862.074
spine court: total s = 7.566 um in the 7.407um regime

-- family: POSITIONAL (pc) (5 levels x 9 obs/level) --
  level means: PC1=-1.376, PC2=3.794, PC3=8.173, PC4=14.091, PC5=18.416
  SSB=2243.543 (df 4)  SSW=275.005 (df 40)  MSB=560.886 MSW=6.875
  F=81.58  eta2=0.8908 (89.1% of SST)
  components: sigma2_family=61.5567  sigma2_within=6.8751
    -> family share of variance = 90.0%

-- family: CYCLICAL (spindle) (3 levels x 15 obs/level) --
  level means: S1=8.537, S2=8.108, S3=9.214
  SSB=9.327 (df 2)  SSW=2509.221 (df 42)  MSB=4.664 MSW=59.743
  F=0.08  eta2=0.0037 (0.4% of SST)
  components: sigma2_family=0.0000  sigma2_within=59.7434
    -> family share of variance = 0.0%

-- family: TEMPORAL (time_block) (3 levels x 15 obs/level) --
  level means: T1=8.067, T2=8.409, T3=9.383
  SSB=13.972 (df 2)  SSW=2504.576 (df 42)  MSB=6.986 MSW=59.633
  F=0.12  eta2=0.0055 (0.6% of SST)
  components: sigma2_family=0.0000  sigma2_within=59.6328
    -> family share of variance = 0.0%

== family chart: bore deviation by pc ==
PC1 |#                                                           |  -1.38 um
PC2 |################                                            |   3.79 um
PC3 |#############################                               |   8.17 um
PC4 |###############################################             |  14.09 um
PC5 |############################################################|  18.42 um
     range of pc means = -1.38 .. 18.42 um (19.79 um spread vs within-cell s = 2.62 um)

== conclusion ==
  positional  90.0%   cyclical 0.0%   temporal 0.0%
  -> variation is concentrated in the POSITIONAL family (F_pc = 82)

court: positional-family decomposition 68.4319 vs total s^2 57.2397
COURT PASS
```

Exit code: 0.

Court assertions carried by the script:
1. TSS witness: centered SST != uncentered sum(y^2) (absolute gap > 1e3).
2. Spine court: total s in (6.9, 7.9) um — the adjudicated 7.407 um regime.
3. Planted signature: positional family share > 0.80.
4. Non-signal families: spindle F < 3 and time-block F < 3.
5. Design balance: 5 pc levels sum to n = 45.

Note on the printed decomposition line: 68.43 = sigma2_family + sigma2_within of the
positional family exceeds total s^2 57.24 because the MSW-based within component of
a one-way cut on a family with an unexplained remaining mean structure is an
UP-biased estimator — disclosed, not hidden; eta^2 (89.1% of raw SST) is the
sample-faithful statistic.

Data regenerable: `python3 modules/25-multi-vari/scripts/gen_multivari_bore.py`
(seed 42501) -> `data/multivari-bore.csv`, 45 rows.
