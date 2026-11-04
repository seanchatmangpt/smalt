# Module 02 Lab — Re-derive the Define Baselines

30 min (inside the 90-min session). From the curriculum root
`/Users/sac/smalt/docs/dmedi-bb-curriculum`.

## Part 1 — DPMO ladder (12 min)

From `data/bore-inspection-dpmo.csv`:
1. Total units inspected and defects found over the 20 days.
2. DPU; then DPMO with 1 opportunity/unit; then with 6 opportunities/unit.
3. z and the sigma level (1.5-shift convention) for the 6-opportunity DPO.
4. Repeat the sigma level for the 1-opportunity DPO. Write one sentence on why
   the method (not the process) moved the number.

## Part 2 — lead-time Y (10 min)

From `data/order-lead-time.csv`:
1. n, mean, median, sd, min, max.
2. P90 (linear interpolation, (n+1)p method).
3. Count and % of orders over the 7-day target.
4. Standard error of the mean; is the pinned registry 18.4 d inside one SE of
   your sample mean?

## Part 3 — Y statements (8 min)

Draft the three CPPC Y statements (CTQ-1 quality, CTQ-2 delivery, CTQ-3 cost),
each one sentence with baseline -> target -> OD -> gate. Cite pins, do not
re-derive them:
- CTQ-1: Cpk 0.72 -> >= 1.33 sustained 30 days (RUNNING-CASE adjudicated pair
  mu 12.009 mm, sigma 7.407 um), OD-1/OD-2, gate W21.
- CTQ-2: your Part 2 median -> <= 7 days, OD-11, gate W15.
- CTQ-3: $41.80 -> <= $28.50 (= $30.00 x 0.95, Module 06 derivation), OD-14/15,
  gate W26.

## Verification

`python3 - <<'EOF'` heredoc, then compare against the solution-key output block.
Court (fail-closed, re-derives everything above):

```bash
python3 modules/02-define-overview/courts/court.py
```
