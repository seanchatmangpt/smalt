# Module 36 Lab — Spindle Reliability Receipt

**Data**: `data/weibull-failure-times.csv` (40 seeded failure times; regenerate with
`python3 scripts/generate_dataset.py` — must be byte-identical).
**Deliverable**: receipt with all numbers re-derived via `python3 courts/court.py`.

## Part 1 — Sample statistics (from the CSV)
1. Sample mean failure time; empirical 10th percentile (interpolate between ranks 4 and 5 of
   the 40 sorted times).
2. Weibull regression estimate of beta and eta (slope/intercept method, F = i/(n+1)).
3. Compare each to the generating law (beta 6.24, eta 1290.7, MTBF 1200, B10 900).

## Part 2 — Exponential check
4. If the same MTBF 1200 h were exponential, compute B10. State the contradiction with the
   spine's 900 h in one sentence.

## Part 3 — Allocation verification
5. Sum the lambda column of the allocation table (slides 3) and re-derive MTBF. Must equal
   1200.0 exactly.

## Part 4 — Availability
6. Compute each component availability and the series A_sys; expected downtime per year.
7. Compute A_sys if the bearing set MTBF drops to 1500 h (MTTR unchanged). Which component
   now dominates the downtime budget?

## Part 5 — Maintenance interval
8. Derive T for F(T) = 1% and 0.1% under (beta 6.24, eta 1290.7).
9. A maintenance planner proposes PM every 900 h "because B10 = 900". Compute F(900) and write
   the one-sentence correction.

## Receipt format
```
subject: modules/36-intro-reliability lab
identity: sha256 of answers + court exit code
replay:   python3 scripts/generate_dataset.py && diff data/weibull-failure-times.csv <(regenerated) && python3 courts/court.py
```
