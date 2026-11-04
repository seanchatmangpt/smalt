# Module 40 Exercises — Inner/Outer Robust Design (Taguchi)

Replay source: `python3 data/compute.py` (exit 0) — regenerates `robust-bore.csv`
(seed 40001) and re-derives every number below.

**Time: 30 min** (Ex 1: 10 min, Ex 2: 10 min, Ex 3: 10 min).

## Exercise 1 — S/N effect for coating (10 min)

From the 8 inner-array runs, compute the coating S/N_STB effect by hand: hi level (coated)
runs are 2, 4, 6, 8; lo level (uncoated) runs are 1, 3, 5, 7.

### Key (derivation shown)

hi (coated): (−14.49 − 17.43 − 10.26 − 11.91)/4 = −54.09/4 = **−13.52 dB**
lo (uncoated): (−16.72 − 20.41 − 16.66 − 17.31)/4 = −71.10/4 = **−17.77 dB**
Effect = −13.52 − (−17.77) = **+4.25 dB** — the key's largest control-factor effect
(speed +3.23, feed −2.24). Python check: `(-14.49-17.43-10.26-11.91)/4 - (-16.72-20.41-16.66-17.31)/4` → 4.25 (exit 0).

## Exercise 2 — Best setup and what it buys (10 min)

The key picks run 6 (V9000/F220/coated), S/N = −10.26 dB, mean 3.23 um, SD 0.49 um.
(a) Compute the S/N_STB of run 6 from its four outer observations [3.61, 3.7, 2.83, 2.78].
(b) Compare run 6's SD to the within-corner pure-error SD from Module 37 (1.886 um) and
state what changed.

### Key (derivation shown)

(a) mean(y²) = (3.61² + 3.70² + 2.83² + 2.78²)/4 = (13.0321 + 13.69 + 8.0089 + 7.7284)/4
= 42.4594/4 = 10.6149 → eta_STB = −10·log10(10.6149) = −10·1.0259 = **−10.26 dB** — matches
the key exactly.
(b) 0.49 um vs 1.886 um: the robust setup cut run-to-run variation by roughly 4× by choosing
factor levels that de-sensitize the mean to the noise factors (hardness, coolant
temperature) — without touching the noise factors themselves.

## Exercise 3 — The control×noise interaction is the robustness mechanism (10 min)

The key shows the coating×hardness interaction: uncoated noise lift +0.84 um, coated noise
lift −0.41 um. In a short paragraph, explain why an interaction with a NOISE factor is what
robust design buys and a plain factorial (Module 30) analysis of the inner array would miss.

### Key (derivation shown)

A control×noise interaction means the factor's effect on the response depends on the noise
level: coating changes the SLOPE of deviation vs hardness (uncoated: hard stock deviates
+0.84 um more; coated: the slope flattens/reverses, −0.41 um). A factorial that averages over
noise (or never varies it) estimates only mean effects and reports "coating helps the mean by
2.87 um" — true but incomplete. Robust design's S/N ratio re-weights the same data toward
variance: because the coating flattens the noise slope, the coated runs have both a lower
mean AND a lower SD (run 6: mean 3.23, SD 0.49), so eta_STB rises +4.25 dB. The decision rule
is choose levels that maximize S/N, then adjust the mean with a separate
mean-only factor — here speed (effect on mean −2.15 um, on S/N only +3.23 dB is
confounded, so adjust with feed), never with the variance-reduction factor itself.
