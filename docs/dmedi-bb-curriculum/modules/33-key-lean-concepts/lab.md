# Module 33 Lab — Decompose the 18.4 Days

**Data**: `data/vsm-baseline.csv` (census of the CPPC order-to-ship stream; no RNG).
**Deliverable**: a receipt with every number re-derived by python3.

## Part 1 — Recompute the baseline decomposition
Load the census CSV. With 1 day = 880 productive minutes:
1. Total wait (sum `wait_days`).
2. Total processing in minutes (sum `process_min`) and in days.
3. Lead time = wait + processing. Compare to the pinned 18.4 d; state the rounding gap.
4. PCE = processing-days / lead-time-days.

## Part 2 — Takt and bottleneck
Demand = 240 housings/day, 2 shifts x 8 h, 80 min planned downtime/day.
5. Takt time in seconds.
6. For each step, cycle time vs takt; identify every step above takt.
7. Mill daily output at 1 vs 2 mills; how many mills does takt require?

## Part 3 — Improvement candidates
Evaluate three candidates and recompute lead time for each (one at a time, all others held):
- C1: anodize queue 4.6 -> 1.0 d (daily vendor pickup, smaller lots).
- C2: pack/transit 3.1 -> 1.0 d (regional carrier, FG pull).
- C3: order entry 2.2 -> 0.5 d (automated scheduling).
8. New lead time under each; which single candidate alone reaches the <= 7 d target?
9. All three together: new lead time and new PCE.

## Receipt format
```
subject: modules/33-key-lean-concepts lab, data/vsm-baseline.csv
identity: sha256 of your filled answer file + court exit code
replay:   python3 courts/court.py            # must exit 0
```
