# Lab — Non-normal capability: when the transformation changes the verdict

Dataset: `data/flatness-lognormal.csv` — 60 flatness measurements (mm),
lognormal process (median 5 um), USL = 0.010 mm, no LSL (flatness is a
larger-the-better-of-small characteristic). Seed 1203.
Key: `python3 modules/12-process-capability/keys/capability_key.py` (part 4).

## Step 1 — look before you compute

skewness = **1.63**, range 0.00215–0.01284, 2 of 60 observations above USL.
Right-skewed — flatness is bounded below by zero with a long upper tail; a
normal model is structurally wrong.

## Step 2 — normality test

Shapiro-Wilk raw: **p = 0.00001** → reject normality decisively.

Decision tree: (a) physical argument for the distribution family
(multiplicative sources → lognormal — flatness, runout, roundness); (b)
Box-Cox for a monotone power fix; (c) Johnson if Box-Cox cannot normalize
(e.g. bimodal) — here Box-Cox suffices, Johnson is the fallback not the route.

## Step 3 — Box-Cox

MLE lambda = **−0.5701** (≈ reciprocal-square-root; strongly non-log,
evidence that the raw tail is heavier than lognormal at this sample).
Transformed Shapiro-Wilk: **p = 0.888** → normality achieved.

## Step 4 — the capability verdict FLIPS

| model | Ppk | est PPM > USL | verdict |
|---|---|---|---|
| raw, normal theory | **0.87** | 4,665 | marginal — "almost there, tighten the process a bit" |
| Box-Cox transformed | **0.64** | 27,344 | **fails** the 1.33 gate outright |
| observed | — | 2/60 = 33,333 | agrees with the transformed model |

The naive normal fit *underestimates* the tail by ~6× (4,665 vs 27,344 PPM)
because the normal density decays faster than the real right tail. Whoever
skipped the normality test would report a nearly-adequate process; the
transformed analysis (and the 2 actual defects in 60) says the process is
far from capable. **The transformation decision changed the verdict from
marginal-pass to fail — that is why it is a gate, not a formality.**

## Step 5 — mechanics of the transformed index

Transform spec with the same lambda: USL* = (USL^λ − 1)/λ; compute Ppk in the
transformed space: Ppk = (USL* − x̄*)/(3 · s*). Never mix: mean/s from the
transformed data with the untransformed spec (or vice versa) is the classic
implementation error. Report Ppk in transformed space; communicate the
verdict, not the transformed units.

## Step 6 — verdict + action

Flatness at Ppk 0.64 (transformed) with ~33,000 PPM: process not capable.
Actions in DMEDI order: (1) confirm the measurement system can even resolve
0.001 mm flatness (module 11 discipline), (2) stratify the tail (which
fixtures/ops produce the >8 um parts), (3) if a bounded-boundary fix lands
first, re-run the whole chain — chart, normality, index — on fresh data.

## Court

The verdict-flip is asserted in code:
`assert Ppk_raw >= 0.8 > Ppk_t` — raw must read marginal-pass, transformed
must fail. A future edit that "fixes" the dataset into normality fails the
court loudly.
