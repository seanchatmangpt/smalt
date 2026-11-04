# Module 38 Exercises — Conjoint Part-Worths and Importance Shares

Replay source: `python3 data/compute.py` (exit 0) — regenerates `conjoint-cards.csv` +
`conjoint-ranks.csv` (seed 38001) and re-derives every number below.

**Time: 30 min** (Ex 1: 10 min, Ex 2: 10 min, Ex 3: 10 min).

## Exercise 1 — Importance shares from the part-worth table (10 min)

From the key run, the part-worth ranges are: price 5.333, lead time 3.000, tolerance 0.667,
finish 0.667.

(a) Verify each range from the part-worth utilities (price: $30 → −2.333, $52 → +3.000).
(b) Compute the four importance shares and confirm they sum to 100%.

### Key (derivation shown)

price range = 3.000 − (−2.333) = **5.333**; lead = 1.667 − (−1.333) = 3.000;
tol = 0.333 − (−0.333) = 0.667; finish = 0.333 − (−0.333) = 0.667.
Total range = 5.333 + 3.000 + 0.667 + 0.667 = 9.667.
Importance: price 5.333/9.667 = **55.2%**, lead 3.000/9.667 = **31.0%**,
tol 0.667/9.667 = 6.9%, finish 0.667/9.667 = 6.9%. Sum = 100.0%. Matches the key run.

## Exercise 2 — Predicted best profile (10 min)

Using the part-worth table, score the profile (price $30, lead 7 days, tol ±0.025 mm,
finish Ra 1.6) and confirm it is the key's BEST profile.

### Key (derivation shown)

u = b0 + b(price $30) + b(lead 7d) + b(tol ±0.025) + b(finish Ra 1.6)
The key prints effect-coded coefficients against lvl0/lvl1 with lvl2 as the balance;
reading the part-worth table directly: $30 = −2.333, 7 days = −1.333, ±0.025 = −0.333,
Ra 1.6 = −0.333.
u = 5.000 − 2.333 − 1.333 − 0.333 − 0.333 = **−4.333** = the key's BEST (predicted rank 1).

## Exercise 3 — Why tolerance looks unimportant (10 min)

The tolerance part-worths are (−0.333, 0.000, +0.333) — a swing of only 0.667, yet Module 37
showed bore deviation is highly sensitive to process parameters. In one paragraph, explain
what the customers in `conjoint-ranks.csv` are actually trading off, and why this does not
contradict the engineering result.

### Key (derivation shown)

The ranks measure willingness-to-pay/lead-time preference of buyers, not physics. In this
panel the buyers treat the tolerance grade as nearly indifferent (they trust the print to be
met at any offered grade) and put 55.2% of their utility weight on price and 31.0% on lead
time. The engineering sensitivity (Module 37's E(B feed) = +2.255 um etc.) describes how the
PROCESS responds, not what the CUSTOMER values. The two live on different response surfaces;
conjoint importance shares are customer-side, engineering effects are machine-side, and a
robust design (Module 40) is what lets the shop sell the cheap tolerance grade profitably.
