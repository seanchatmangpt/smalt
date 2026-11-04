# Module 32 Exercises — Catapult Lab (16+4, Curvature)

Source: `data/catapult-results.csv` (20 rows, seed 43201, registered — no new
seeds; regenerate with `python3 data/simulator.py`, sha256-pinned
a63fd239…6517). Every number below is pinned by `court.py` (exit 0 = 16+4
split, 15 contrast means, curvature t, best run, sha256 all re-derive;
sign-flip mutation detected). Re-run, do not trust.

**Time: 40 min** (Ex 1: 12 min, Ex 2: 12 min, Ex 3: 8 min, Ex 4: 8 min).

## Exercise 1 — Effects as contrast means (12 min)

From the 16 corner runs, compute the effects as contrast means
(effect = mean of signed distances). Court-pinned: A +0.5090, B +0.5021,
C −0.4342, AB +0.1920, BC −0.1634, AC −0.1632, ABC −0.0623, D +0.0044; all
D-interactions ≤ 0.004; ABCD ≤ 0.0027. Full 2^4 — no aliasing.

(a) Rank the effects and name the naive "best corner" prediction.
(b) Check the best observed corner run against it.

### Key (derivation shown)

(a) Ranking: A ≈ B (+0.51 each) > |C| (−0.4342) > AB (+0.1920) > |BC| ≈ |AC|
    (~0.163) > ABC (0.062) > D (+0.0044 ≈ 0). Naive read: raise A, raise B,
    drop C, ignore D → best corner A+B+−C (D indifferent).
(b) Best observed run: std_order 3 (A+, B+, C−, D+) at **3.3372 m**
    (court-pinned); factorial mean 1.3072 m. So far the naive read wins —
    Ex 2 is where it breaks.

## Exercise 2 — The curvature test (12 min)

Using the 4 center points (std_order 17–20): court-pinned center mean 1.2415 m,
center sd 0.0119 m (df 3), factorial mean 1.3072 m, diff −0.0657 m, se 0.0067,
t = −9.86, t_crit(0.025, 3) = 3.182.

(a) Re-derive se and t by hand.
(b) State the verdict AND the direction, with the physical mechanism.

### Key (derivation shown)

(a) sp = 0.0119; se = sp·√(1/4 + 1/16) = 0.0119·√0.3125 = **0.0067 m**;
    t = −0.0657 / 0.0067 = **−9.86**. |t| = 9.86 > 3.182 → **significant**.
(b) The curvature is **negative** (center BELOW the corner-anchored plane):
    range ∝ v² ∝ (θ·L/√m)² is convex in A, B, C, and the center of a convex
    arc sits below the chord. D's true effect is a large quadratic wearing a
    zero main effect — sin(2α) peaks at α = 45°, exactly D's center level, so
    the ±1 linear contrast cancels while the center point pays full price.
    Verdict: the plane is unfit for extrapolation — do NOT chase the corner
    with a first-order model; schedule a second-order (RSM, Module 41)
    exploration centered near A+, B+, C− with D's quadratic in the model.

## Exercise 3 — Why the Pareto acquits D (8 min)

D's main effect is +0.0044 m; sp = 0.0119 m. Show that a linear-effect court
would acquit D, and explain why the curvature test is the load-bearing check
instead.

### Key (derivation shown)

|E(D)| = 0.0044 < sp = 0.0119 — D's linear contrast sits inside 0.4·sp, deep
in the noise floor. A Pareto of main effects retires D as inert. But the
center points see the quadratic: sin(2α) is symmetric about 45°, so the ±1
levels (symmetric about the peak) cancel in the linear contrast while the
center level sits at the peak's maximum range — the −0.0657 m deficit is the
quadratic's signature, and it is 15x sp. Lesson: a zero main effect is not
evidence of a null factor when curvature is present; the center points are the
only runs that can testify.

## Exercise 4 — Provenance chain (8 min)

Regenerate the dataset and prove byte-identity:

```
python3 data/simulator.py && shasum -a 256 data/catapult-results.csv
```

State the expected sha256 and why byte-identity matters for a court-pinned
exercise set.

### Key

Expected: **a63fd2395b14291224d38d683624b99c528aeebe77e944f7dc7ba2f25c4a6517**
(identical across two regenerations — key §0 receipt). Byte-identity is what
lets every number in Ex 1–3 be a pinned constant rather than a re-sampled
draw: same seed 43201, same noise sequence, same 20 rows, same verdicts. A
mismatch sha is a drift finding — stop, diagnose, fix toward the registered
manifest.

## See also

README §3 (lab flow), §5 (teachable twist), `solution-key.md` (court
receipts); Module 37 (center-point curvature test, worked on the bore
response); Module 41 (RSM — the second-order follow-up).
