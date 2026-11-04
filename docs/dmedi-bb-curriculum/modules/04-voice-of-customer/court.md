# Module 04 Court

**Verdict command** (exit 0 = PASS, exit 1 = FAIL):

```bash
python3 modules/04-voice-of-customer/court.py          # exit 0 = PASS
python3 modules/04-voice-of-customer/court.py --mutate # must exit 1
```

The executable court re-derives the same pins independently (its own embedded
Kano table, weight table, gap math) from `data/kano-responses.csv`; the
deriving script below remains the key-side derivation.

from the repo root `/Users/sac/smalt/docs/dmedi-bb-curriculum`. The court is the
same script that derives the solution key, so the key cannot drift from the data.

## What the court checks (fail-closed)
1. Dataset contract: 12 respondents × 10 Kano attributes (K-01..K-10), 12 rows per attribute.
2. Kano classification of all 120 response pairs via the 3×3 evaluation table;
   majority rule (ties toward stronger demand class, order M > O > A > I > R).
3. Expected-class table: K-01/2/3 = M, K-04/5/6 = O, K-07/8 = A,
   K-09/K-10 = I. K-10 = I is the historically mislabeled row (prior lane
   instance died on it); the court is the non-vacuity proof — it FAILS if any
   majority moves off its expected class.
4. CR1–CR9 rank→weight table: point pool 45, normalized sum 1.0.
5. Spine Cpk honest-flag: re-derives Cpk from pinned mu 12.009 / sigma 7.407 um
   (the pair ADJUDICATED 2026-11-04, see RUNNING-CASE.md) and asserts it equals
   the pinned 0.72; it also prints the adjudicated sigma (7.407 um) that yields
   0.72 at mu = 12.009 mm — registered in the MANIFEST cross-module note and
   carried into Module 05's court. (Historical: the ORIGINAL spine sigma
   4.17 um yielded 1.279 and was adjudicated stale.)

## Non-vacuity
Mutating any single (func, dys) cell of a K-10 row in the CSV flips K-10 off I
and exits 1 (this is the exact check that caught the prior instance's "M" label).
Mutating the ranks table moves a weight and exits 1 on the sum check.
