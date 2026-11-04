# Module 40 Lab — Inner/Outer Robust Design (Taguchi S/N)

**Objective**: run an L8 inner array (speed, feed, coating) crossed with a 2² outer array
(hardness, coolant temperature), compute S/N_STB per inner run, find the robust setup, and
expose the control×noise interaction as the robustness mechanism.

**Dataset**: `data/robust-bore.csv` — 8 inner × 4 outer = 32 runs, seed 40001 (hardcoded in
`data/compute.py`; the script regenerates the CSV byte-identically — manifest-registered
sha256 `8ac178b1…c1ad`).

**Replay incantation** (from the curriculum root):

```bash
python3 modules/40-robust-design/data/compute.py; echo RC=$?    # RC=0
python3 modules/40-robust-design/courts/court.py; echo RC=$?    # RC=0, 43/43 checks
```

**Time: ~30 min** (Lab 1: 12 min, Lab 2: 10 min, Lab 3: 8 min).

## Lab 1 — The 32-run S/N table (12 min)

Per inner run, compute mean, SD, and eta_STB = −10·log10(mean(y²)) over the 4 outer
observations. Checkpoint table (court-pinned, every row re-derived independently):

| run | speed | feed | coating | mean (µm) | SD (µm) | S/N_STB (dB) | S/N_LTB (dB) |
|---|---|---|---|---|---|---|---|
| 1 | V6000 | F220 | uncoated | 6.79 | 1.07 | −16.72 | 30.10 |
| 2 | V6000 | F220 | coated | 5.12 | 1.60 | −14.49 | 31.75 |
| 3 | V6000 | F340 | uncoated | 10.34 | 1.94 | −20.41 | 28.68 |
| 4 | V6000 | F340 | coated | 7.22 | 2.08 | −17.43 | 30.00 |
| 5 | V9000 | F220 | uncoated | 6.79 | 0.42 | −16.66 | 30.53 |
| 6 | V9000 | F220 | coated | **3.23** | **0.49** | **−10.26** | 31.84 |
| 7 | V9000 | F340 | uncoated | 6.97 | 2.64 | −17.31 | 28.88 |
| 8 | V9000 | F340 | coated | 3.86 | 0.92 | −11.91 | 31.24 |

**Checkpoint (court-pinned S/N effects)**: speed +3.23 dB, feed −2.24 dB,
coating **+4.25 dB** (largest). Mean effects: speed −2.15 µm, feed +1.62 µm,
coating −2.87 µm.

## Lab 2 — Best setup and the S/N re-derivation (10 min)

**Checkpoint (court-pinned)**: best setup on S/N_STB is run 6 (V9000/F220/coated),
S/N = −10.26 dB, mean 3.23 µm, SD 0.49 µm. From its raw deviations [3.61, 3.70, 2.83, 2.78]:
mean(y²) = 42.4594/4 = 10.6149 → eta_STB = −10·log10(10.6149) = **−10.26 dB** (hand
arithmetic matches the court exactly). Same data through other lenses: eta_NTB +16.34 dB;
eta_LTB on tool life [41.9, 40.3, 39.2, 35.8] = 31.84 dB.

Compare run 6's SD 0.49 µm to Module 37's within-corner pure-error SD 1.886 µm: ~4×
variation reduction without controlling the noise factors.

## Lab 3 — The control×noise interaction (8 min)

**Checkpoint (court-pinned noise lifts)**: uncoated soft 7.30 µm vs hard 8.14 µm →
**+0.84 µm**; coated soft 5.06 µm vs hard 4.65 µm → **−0.41 µm**. Coating flattens the
hardness slope — that interaction with a NOISE factor is what robust design buys and what a
plain factorial (Module 30) analysis of the inner array alone cannot see. Decision rule:
pick variance-control levels on S/N, adjust the mean with a separate mean-only lever
(here feed), never the variance-reduction factor itself.

## Tool note

Stdlib-only (`csv`, `math`, `statistics`); no Minitab/R required. Non-vacuity witnessed:
mutating run 6's first deviation (3.61 → 9.00) flips the court to exit 1 (12 FAILs) and the
restore is sha256-verified byte-exact. `python3 datasets/manifest_verify.py` must stay
exit 0 (61 PASS, 0 FAIL).

## Receipt format

```
subject: modules/40-robust-design lab
identity: sha256 of answers + court exit code
replay:   python3 modules/40-robust-design/data/compute.py && python3 modules/40-robust-design/courts/court.py
```
