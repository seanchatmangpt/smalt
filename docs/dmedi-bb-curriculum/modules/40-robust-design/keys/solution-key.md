# Module 40 Solution Key — L8 inner × 2² outer robust design, seed 40001 (all numbers re-derived)

Command incantation (run from the curriculum root):

```
python3 modules/40-robust-design/data/compute.py; echo RC=$?   # RC=0
```

The script regenerates `data/robust-bore.csv` deterministically — the seed
(40001) is hardcoded in `data/compute.py`, no seed argument is taken.
Verified this session: sha256 of the CSV is byte-identical before and after
the run (`8ac178b1…c1ad`, the exact digest registered in
`datasets/MANIFEST.md`), so the printed numbers are the manifest-registered
dataset's numbers.

Full captured output of that run (every number below re-derives from this
output, zero copied):

```
== Module 40 solution key: inner/outer robust design ==
inner L8 (control: speed, feed, coating) x outer 4 (noise: hardness, coolant temp) = 32 runs

run speed   feed   coat       mean_um     s  S/N_STB   life  S/N_LTB
1   V6000   F220   uncoated      6.79  1.07   -16.72   32.0    30.10
2   V6000   F220   coated        5.12  1.60   -14.49   39.0    31.75
3   V6000   F340   uncoated     10.34  1.94   -20.41   27.3    28.68
4   V6000   F340   coated        7.22  2.08   -17.43   31.8    30.00
5   V9000   F220   uncoated      6.79  0.42   -16.66   33.8    30.53
6   V9000   F220   coated        3.23  0.49   -10.26   39.3    31.84
7   V9000   F340   uncoated      6.97  2.64   -17.31   27.9    28.88
8   V9000   F340   coated        3.86  0.92   -11.91   36.6    31.24

-- control-factor mean effects on S/N_STB (dB) --
  speed    lo -17.26  hi -14.03  effect  +3.23 dB
  feed     lo -14.53  hi -16.76  effect  -2.24 dB
  coating  lo -17.77  hi -13.52  effect  +4.25 dB

-- control-factor effects on the MEAN deviation (um) --
  speed    lo   7.37  hi   5.21  effect  -2.15
  feed     lo   5.48  hi   7.10  effect  +1.62
  coating  lo   7.72  hi   4.86  effect  -2.87

best setup on S/N_STB: run 6 (V9000/F220/coated) S/N = -10.26 dB, mean 3.23 um, SD 0.49 um

-- noise main effects (averaged over all 8 controls) --
  soft +cool  mean deviation   5.38 um
  soft +warm  mean deviation   6.98 um
  hard +cool  mean deviation   5.47 um
  hard +warm  mean deviation   7.33 um

-- coating x hardness interaction (control x noise) --
  uncoated  soft  7.30 um | hard  8.14 um | noise lift +0.84 um
  coated    soft  5.06 um | hard  4.65 um | noise lift -0.41 um

-- S/N family comparison on run 6's four outer observations --
  deviations (um): [3.61, 3.7, 2.83, 2.78]
  eta_STB = -10log10(mean(y^2))          = -10.26 dB
  eta_NTB = 10log10(ybar^2/s^2)          = 16.34 dB
  eta_LTB on tool life [41.9, 40.3, 39.2, 35.8] = 31.84 dB
```

## Gate receipts (this session, curriculum root)

| gate | command | result |
|---|---|---|
| court | `python3 modules/40-robust-design/courts/court.py` | **exit 0** — 43/43 PASS, "MODULE 40 COURT: PASS (0 failures)" |
| non-vacuity | mutate one cell (run-6 first deviation 3.61 → 9.00), rerun court | **exit 1**, 12 FAILs; `git checkout` restore byte-exact (sha256 match) |
| manifest | `python3 datasets/manifest_verify.py` | **exit 0** — 61 PASS, 0 SKIP, 0 FAIL |

## Per-run table vs the court's pinned constants

The court re-derives all 32-run S/N values from `data/robust-bore.csv` and
pins (mean_um, S/N_STB, S/N_LTB) per inner run:

| run | speed | feed | coating | mean_um (court) | S/N_STB dB (court) | S/N_LTB dB (court) | compute.py output |
|---|---|---|---|---|---|---|---|
| 1 | V6000 | F220 | uncoated | 6.79 | −16.72 | 30.10 | identical |
| 2 | V6000 | F220 | coated | 5.12 | −14.49 | 31.75 | identical |
| 3 | V6000 | F340 | uncoated | 10.34 | −20.41 | 28.68 | identical |
| 4 | V6000 | F340 | coated | 7.22 | −17.43 | 30.00 | identical |
| 5 | V9000 | F220 | uncoated | 6.79 | −16.66 | 30.53 | identical |
| 6 | V9000 | F220 | coated | **3.23** | **−10.26** | 31.84 | identical |
| 7 | V9000 | F340 | uncoated | 6.97 | −17.31 | 28.88 | identical |
| 8 | V9000 | F340 | coated | 3.86 | −11.91 | 31.24 | identical |

Run 6 raw deviations pinned by the court: [3.61, 3.70, 2.83, 2.78] —
matches the CSV and the captured output exactly. Best setup on S/N_STB:
run 6 (V9000/F220/coated) — court check "best run on S/N is 6" PASS.

## E1 — Coating S/N effect by hand

hi (coated) runs 2/4/6/8: (−14.49 − 17.43 − 10.26 − 11.91)/4 = **−13.52 dB**
lo (uncoated) runs 1/3/5/7: (−16.72 − 20.41 − 16.66 − 17.31)/4 = **−17.77 dB**
Effect = −13.52 − (−17.77) = **+4.25 dB** — the largest control-factor effect
(speed +3.23 dB, feed −2.24 dB; court pins all three: 3.23 / −2.24 / 4.25).
Mean-effect companion values pinned by the court: speed −2.15 µm,
feed +1.62 µm, coating −2.87 µm.

## E2 — Best setup: S/N re-derivation and what it buys

**(a)** Run 6 outer observations [3.61, 3.70, 2.83, 2.78]:
mean(y²) = (13.0321 + 13.69 + 8.0089 + 7.7284)/4 = 42.4594/4 = 10.6149
eta_STB = −10·log10(10.6149) = −10 × 1.0259 = **−10.26 dB** — matches the
court's pinned run-6 S/N_STB exactly. (Same data through the NTB lens:
ȳ²/s² gives +16.34 dB; through LTB on tool life [41.9, 40.3, 39.2, 35.8]:
31.84 dB.)

**(b)** Run 6's SD 0.49 µm vs Module 37's within-corner pure-error SD
1.886 µm: the robust setup cut run-to-run variation by ~4× — not by removing
the noise factors (hardness, coolant temperature were never controlled), but
by choosing control levels that de-sensitize the mean to them. S/N rose from
the −17/−20 dB range to −10.26 dB.

## E3 — The control×noise interaction IS the robustness mechanism

| coating | dev @ soft stock | dev @ hard stock | noise lift |
|---|---|---|---|
| uncoated | 7.30 µm | 8.14 µm | **+0.84 µm** |
| coated | 5.06 µm | 4.65 µm | **−0.41 µm** |

(court pins both lifts: +0.84, −0.41.) An interaction with a NOISE factor
means the control factor changes the *slope* of the response against the
noise, not just its level. A plain Module-30 factorial over the inner array
alone never sees this: it averages over (or never varies) noise and would
report only "coating helps the mean by 2.87 µm" — true but incomplete. The
S/N ratio re-weights the same 32 observations toward variance: because
coating flattens the hardness slope, coated runs have both lower mean and
lower SD (run 6: 3.23 µm / 0.49 µm), so eta_STB rises +4.25 dB. Decision
rule: pick variance-control levels on S/N, then set the mean with a separate
mean-only lever — here feed (+1.62 µm on the mean, only −2.24 dB on S/N) is
the adjuster, never the variance-reduction factor itself.
