# Module 40 — Robust Design (Taguchi): Control × Noise, Inner/Outer Arrays, S/N

**Module**: 40-robust-design
**Learning objectives** — after this module the Black Belt candidate can:
1. Frame robustness as control×noise interaction: choose control settings that make the response *insensitive* to noise, not just settings with a good average.
2. Build an inner/outer array design: L8 inner for controls, 2^2 outer for noise, 32 measured runs.
3. Compute all three S/N families (smaller-the-better, nominal-the-best, larger-the-better) from raw outer-array observations.
4. Select the optimal setup on S/N, show why the mean-only ranking differs, and read a control×noise interaction (coating damps hardness noise).
5. Connect the result back to the running case: the chosen setup is the "improved process" that module 41-style confirmation and the control plan carry forward.

**Timing estimate**: 4.0 h (slides 1.5 h, lab 1.25 h, exercises 0.5 h, court/self-check 0.75 h).
**Required tools**: python3 stdlib only. Solution key: `data/compute.py` — regenerates `robust-bore.csv` (seed 40001) and re-derives every number below.

**Running-case anchor**: CPPC bore diameter. Control factors (per RUNNING-CASE.md DOE factors): spindle speed (6000/9000 RPM), feed rate (220/340 mm/min), tool coating (uncoated/coated). Noise factors (the case's environmental reality): bar-stock hardness variation (soft/hard lots), coolant temperature drift (cool/warm). Response: bore deviation from 12.000 mm, µm.

---

## Slide 1 — The robustness idea (10 min)
- Classical DOE (modules 30/37) asks "what settings give the best average response at nominal conditions?"
- The shop floor is not nominal: bar lots vary, coolant warms through a shift. A setup with a great mean that collapses on hard stock is not an improvement.
- Taguchi's move: measure **variance across noise** at each control setting and optimize a signal-to-noise ratio. Two-step recipe: (1) maximize S/N, (2) adjust a mean-shifting factor to bring the mean on target.
- Control×noise interaction is the mechanism: a factor whose effect *changes across noise levels* is the robustness lever.

## Slide 2 — Inner/outer array (15 min)
- Inner array = control factors (things the engineer sets): L8 = full 2^3 for speed/feed/coating.
- Outer array = noise factors (things the environment does): 2^2 for hardness × coolant temp = 4 conditions.
- Cross the two: each control setting is tried under all 4 noise conditions → 8 × 4 = 32 runs. This crossing is what lets us *observe* variability caused by noise, not estimate it from assumptions.
- Cost note: full crossing is expensive; that is the honest price of measuring robustness. Fractional outers are the standard economy, at the usual aliasing cost.

## Slide 3 — The S/N families (15 min, formulas + when)
With outer-array observations y1..yn for one control run:

- **Smaller-the-better** (bore deviation, target 0): `eta_STB = −10·log10( mean(y_i²) )`
- **Nominal-the-best** (dimension on target, variance matters): `eta_NTB = 10·log10( ȳ² / s² )`
- **Larger-the-better** (tool life, strength): `eta_LTB = −10·log10( mean(1/y_i²) )`
- All are in decibels; all fold mean and spread into one number. dB scale matters: effects add, and a "small-looking" linear difference can be a large ratio (10 dB = ×10 on the ratio inside the log).

## Slide 4 — The data and per-run table (15 min, from the key)
`python3 data/compute.py` (seed 40001) prints, per inner run:

| run | speed | feed | coating | mean µm | s | S/N_STB dB | life min | S/N_LTB dB |
|---|---|---|---|---|---|---|---|---|
| 1 | V6000 | F220 | uncoated | 6.79 | 1.07 | −16.72 | 32.0 | 30.10 |
| 2 | V6000 | F220 | coated | 5.12 | 1.60 | −14.49 | 39.0 | 31.75 |
| 3 | V6000 | F340 | uncoated | 10.34 | 1.94 | −20.41 | 27.3 | 28.68 |
| 4 | V6000 | F340 | coated | 7.22 | 2.08 | −17.43 | 31.8 | 30.00 |
| 5 | V9000 | F220 | uncoated | 6.79 | 0.42 | −16.66 | 33.8 | 30.53 |
| 6 | V9000 | F220 | coated | **3.23** | **0.49** | **−10.26** | 39.3 | **31.84** |
| 7 | V9000 | F340 | uncoated | 6.97 | 2.64 | −17.31 | 27.9 | 28.88 |
| 8 | V9000 | F340 | coated | 3.86 | 0.92 | −11.91 | 36.6 | 31.24 |

## Slide 5 — S/N effects and the decision (20 min, worked)
```
control-factor mean effects on S/N_STB (dB):
  speed    effect +3.23 dB    (V9000 better)
  feed     effect -2.24 dB    (F220 better)
  coating  effect +4.25 dB    (coated better)
best setup on S/N_STB: run 6 (V9000/F220/coated)
  S/N = -10.26 dB, mean 3.23 um, SD 0.49 um
```
- Ranking on the mean alone gives the same winner here, but notice run 5 (V9000/F220/uncoated): mean 6.79 µm ties run 1, yet its SD is 0.42 vs 1.07 — the mean hides that speed *stabilizes* the process. S/N sees it; the mean does not.
- Both S/N_LTB and the mean-life column agree coated is the life choice — two responses, one setting, no conflict. When S/N columns disagree across responses, that is a trade-off discussion, not a computation error.

## Slide 6 — Noise structure and the control×noise interaction (20 min, worked)
Noise main effects (averaged over all controls):
```
  soft+cool  5.38 um | soft+warm  6.98 um | hard+cool  5.47 um | hard+warm  7.33 um
```
Coolant temperature is the dominant noise (+1.7 µm warm vs cool); hardness is minor on average — **on average**. The interaction tells the real story:
```
coating x hardness interaction (control x noise):
  uncoated  soft 7.30 um | hard 8.14 um | noise lift +0.84 um
  coated    soft 5.06 um | hard 4.65 um | noise lift -0.41 um
```
- Uncoated tools degrade on hard stock (+0.84 µm); coated tools are *flat across hardness* (−0.41 ≈ 0). The coating is not just shifting the mean — it is **removing a noise sensitivity**. That is robust design in one table.
- Teaching point: a control main effect computed on noise-averaged data can mask an interaction; always split the S/N analysis by noise level before declaring a factor "robustness lever".

## Slide 7 — All three families on one run (10 min, worked)
Run 6's outer observations: deviations [3.61, 3.70, 2.83, 2.78] µm, tool life [41.9, 40.3, 39.2, 35.8] min:
```
eta_STB = -10log10(mean(y^2))          = -10.26 dB
eta_NTB = 10log10(ybar^2/s^2)          =  16.34 dB
eta_LTB (tool life)                    =  31.84 dB
```
- Which family is *correct* here? STB — deviation's target is exactly 0 and any variance around 0 is equally bad. NTB is shown for completeness and to expose its trap: with ȳ ≈ 3.2 and target 0, maximizing ȳ²/s² would push the mean *away* from target — using NTB on an STB problem rewards the wrong thing.
- Rule the candidate must be able to state: family follows the response's target (0 / nominal / infinity), never analyst preference.

## Slide 8 — Why-it-works (10 min)
- S/N_STB is monotone in mean(y²), which is exactly the mean-squared error decomposition: mean(y²) = ȳ² + s². Maximizing S/N simultaneously shrinks bias and variance — one statistic, both failure modes.
- dB scale is a variance-stabilizing transform: ratios of process variation become additive effects, which is what the effect-estimation machinery of modules 30/37 needs.
- Confirmation law: run 6's S/N of −10.26 dB is a claim. The control plan (module downstream) requires a confirmation lot: 30 parts at V9000/F220/coated, S/N and Cpk re-derived from the real parts before the setting is released to production.

## Lab — candidate executes (75 min)
1. `python3 data/compute.py` → exit 0; reproduce the per-run table and effects exactly.
2. Hand-compute S/N_STB for run 1 from its four raw deviations in the CSV; match −16.72 dB.
3. Recompute the effect table using only the hard-stock outer rows; report which control effect moves most and explain via the coating×hardness interaction.
4. Two-step recipe practice: after choosing V9000/F220/coated, identify from the data whether any control factor adjusts the *mean* without hurting S/N; if none exists in this design, say so and state what a follow-up design must add.
5. Court question: show numerically why eta_LTB would be undefined if a tool-life observation were exactly 0, and what that implies about measurement resolution for LTB responses.
6. Non-vacuity check: flip the coating labels of runs 2 and 6 in the CSV; the S/N ranking must move; restore from seed.

## Court / self-check (exit-checked)
- `python3 data/compute.py` exits 0; every number in slides 4–7 re-derives from `robust-bore.csv`.
- Balance check: each inner run has exactly 4 outer observations (32 total) — candidate writes and passes the check.
- Coherence: control factors and response match RUNNING-CASE.md pinned DOE factors; noise factors are the machining-shop realities named in the case.

## See also
Module 29/30 (DOE fundamentals, orthogonal arrays), 37 (curvature: the post-robustness question "does the improved region still bend?"), 38 (same OA machinery for survey cards), 41 (sequential RSM lab: the confirmation-step methodology in full).
