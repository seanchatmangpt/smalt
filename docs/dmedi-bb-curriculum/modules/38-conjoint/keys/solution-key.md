# Module 38 Solution Key — Conjoint Part-Worths, seed 38001 (all numbers re-derived)

Command incantation (run from the curriculum root; seed 38001 is stated inside
`data/compute.py` — the L9 card design is authored (no RNG), the 9 card ranks
draw gauss(0, 0.55) noise on true utility, and the script regenerates
`conjoint-cards.csv` + `conjoint-ranks.csv` byte-identically before re-deriving
every printed number from the CSVs on disk):

```
python3 modules/38-conjoint/data/compute.py; echo RC=$?   # RC=0
```

Full captured output of that run (every number below re-derives from this
output, zero copied):

```
== Module 38 solution key: conjoint part-worths via OLS (rank regression) ==
effect coding, dependent variable = card rank (1 = most preferred;
negative coefficients therefore indicate preferred levels)

intercept b0 (mean rank) = 5.000
  b(price:lvl0  ) = +3.000
  b(price:lvl1  ) = -0.667
  b(lead:lvl0   ) = +1.667
  b(lead:lvl1   ) = -0.333
  b(tol:lvl0    ) = -0.333
  b(tol:lvl1    ) = +0.000
  b(finish:lvl0 ) = -0.333
  b(finish:lvl1 ) = +0.000

-- part-worth utility table (rank scale; more negative = more preferred) --
  price   $52.00: +3.000, $38.00: -0.667, $30.00: -2.333
  lead    15 days: +1.667, 10 days: -0.333, 7 days: -1.333
  tol     +/-0.025 mm: -0.333, +/-0.015 mm: +0.000, +/-0.008 mm: +0.333
  finish  Ra 1.6: -0.333, Ra 0.8: +0.000, Ra 0.4: +0.333

-- attribute importance (range share) --
  price   range = 5.333  importance =  55.2%
  lead    range = 3.000  importance =  31.0%
  tol     range = 0.667  importance =   6.9%
  finish  range = 0.667  importance =   6.9%

-- predicted best / worst profiles (of all 81) --
  BEST (predicted rank 1): u = -4.333  [price=$30.00, lead=7 days, tol=+/-0.025 mm, finish=Ra 1.6]
  WORST (predicted rank 9): u = +5.333  [price=$52.00, lead=15 days, tol=+/-0.008 mm, finish=Ra 0.4]
```

Court receipt: `python3 modules/38-conjoint/courts/court.py` →
`MODULE 38 COURT: PASS (0 failures)`, RC=0 (26/26 checks incl. L9 balance,
rank permutation, level-mean-route part-worths, importance shares, and the
saturated-design OLS refit with residual SD ≈ 0).

## E1 — Importance shares from the part-worth table

| attribute | part-worths (rank scale) | range | importance | court pin (±0.05) |
|---|---|---|---|---|
| price | +3.000 / −0.667 / −2.333 | 5.333 | **55.2%** | 55.2 |
| lead | +1.667 / −0.333 / −1.333 | 3.000 | **31.0%** | 31.0 |
| tol | −0.333 / 0.000 / +0.333 | 0.667 | **6.9%** | 6.9 |
| finish | −0.333 / 0.000 / +0.333 | 0.667 | **6.9%** | 6.9 |

Total range = 9.667. Derivation: price = 3.000 − (−2.333) = 5.333;
5.333/9.667 = 55.2%; 3.000/9.667 = 31.0%; 0.667/9.667 = 6.9% (×2).
Sum = 100.0%. Court re-derives every part-worth by an independent route
(level means − 5, exact by L9 orthogonality) and matches to ±0.01.

## E2 — Predicted best profile

Reading the part-worth table: $30 = −2.333, 7 days = −1.333, ±0.025 = −0.333,
Ra 1.6 = −0.333.
u = b0 + Σ = 5.000 − 2.333 − 1.333 − 0.333 − 0.333 = **−4.333** = the key's
BEST (predicted rank 1): price $30, lead 7 days, tol ±0.025 mm, finish Ra 1.6.
The WORST of all 81 profiles is the mirror: $52 / 15 days / ±0.008 / Ra 0.4,
u = **+5.333** (mirror of −4.333 around the b0 = 5.000 mean rank — the effect
coding makes the 81-profile utility surface exactly antisymmetric).

## E3 — Why tolerance looks unimportant

The ranks measure buyer trade-offs, not physics. This panel puts 55.2% of
utility weight on price and 31.0% on lead time and treats the tolerance grade
as nearly indifferent (range 0.667, 6.9%). Module 37's engineering effects
(E(B feed) = +2.255 µm) describe how the PROCESS responds; conjoint
importance is what the CUSTOMER values — different response surfaces, no
contradiction. Robust design (Module 40) is what lets the shop sell the cheap
tolerance grade profitably.

## Court vs key cross-check

| court check (level-mean route) | court expected | key/captured | verdict |
|---|---|---|---|
| price $52 / $38 / $30 | +3.000 / −0.667 / −2.333 | same | PASS |
| lead 15d / 10d / 7d | +1.667 / −0.333 / −1.333 | same | PASS |
| tol ±0.025 / ±0.015 / ±0.008 | −0.333 / 0.000 / +0.333 | same | PASS |
| finish Ra 1.6 / Ra 0.8 / Ra 0.4 | −0.333 / 0.000 / +0.333 | same | PASS |
| importance % (tol 0.05) | 55.2 / 31.0 / 6.9 / 6.9 | same | PASS |
| refit residual SD (±0.25) | 0.0 | 0.0000 | PASS |

Mutation gate (anti-vacuity): `python3
modules/38-conjoint/courts/court.py --mutate` exits 1 (MUTATION DETECTED —
corrupted pinned importance share still must fail the check; a corrupt value
that still passes would exit 2 as VACUOUS COURT).
