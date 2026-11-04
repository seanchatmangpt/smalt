# Module 33 Solution Key (all numbers python3-re-derived; see courts/court.py)

## Part 1 — Baseline decomposition (from data/vsm-baseline.csv)
- Wait total = 2.2 + 2.1 + 2.6 + 1.2 + 4.6 + 1.8 + 3.1 = **17.6 d**.
- Processing total = 0 + 4.5 + 6.8 + 2.2 + 660.0 + 2.5 + 1.5 = **677.5 min**.
- 1 day = 880 productive min -> processing = 677.5/880 = **0.7699 d**.
- Lead time = 17.6 + 0.7699 = **18.37 d**, vs pinned 18.4 d: gap 0.03 d, within CSV one-decimal
  rounding of seven queued rows. The court accepts |18.37 − 18.4| <= 0.05.
- PCE = 0.7699/18.37 = **4.19%** (course rounds to 4.2%).

## Part 2 — Takt and bottleneck
- Net available = 2 x 8 h x 60 − 80 = 880 min = 52,800 s/day.
- Takt = 52,800/240 = **220 s**.
- Step cycle times vs takt: saw 270 s (1.23x), **mill 408 s (1.86x — above takt)**, deburr
  132 s, anodize 660 min lot time is a batch step (not cycle-limited), CMM 150 s, pack 90 s.
- Mill output at 1 mill: 880/6.8 = **129 housings/day** (< 240 demand — the mill caps the line).
- Takt requires **2 mills**: 408/2 = 204 s <= 220 s.

## Part 3 — Improvement candidates
- C1 (anodize 4.6 -> 1.0): lead time 18.37 − 3.6 = **14.77 d**.
- C2 (pack 3.1 -> 1.0): 18.37 − 2.1 = **16.27 d**.
- C3 (order entry 2.2 -> 0.5): 18.37 − 1.7 = **16.67 d**.
- No single candidate reaches 7 d (best is C1 at 14.77 d).
- All three: 17.6 − (3.6 + 2.1 + 1.7) = 10.2 d wait; lead time 10.2 + 0.77 = **10.97 d**.
  Still above 7 d: the remaining pools (saw 2.1, mill 2.6, deburr 1.2, CMM 1.8 = 7.7 d) must
  also be attacked; e.g. pull/kanban between internal ops to ~0.5 d each removes 5.7 d more ->
  **5.27 d <= 7 d** target met. New PCE = 0.77/5.27 = **14.6%**.
- Teaching point: the <= 7 d target is NOT reachable by fixing only the top-3 pools; it needs
  the internal queues re-designed too.

## Exercise answers
1. Takt = 52,800/300 = **176 s**. Mill 408 s -> needs **3 mills** (408/3 = 136 <= 176; 2 mills =
   204 s > 176). Saw 270 s: 270/2 = 135 <= 176 (saw crosses takt at 300/day too — needs 2 saws,
   since 270 > 176). Deburr 132 <= 176 OK. Any step with cycle > 176 crosses: saw and mill.
2. Motion and waiting are not columns: waiting IS the wait_days column (so the two not directly
   visible are **motion** (CMM walk distance — needs a spindle-distance study) and **defects**
   (rework % — needs lot rework records; stated 8% in slides, not in the CSV)).
3. Little's Law: L = 129 x 2.6 = **335 housings** average mill queue. At W = 1.0 d:
   L = 129 x 1.0 = 129 housings.
4. Against elimination: Cpk 0.72 means ~4.7% out of spec... (at Cpk 0.72, expect roughly
   9,000–20,000 ppm nonconforming depending on distribution shift) — final verification is
   doing real work. For: duplicate verification is overprocessing waste IF capability is
   proven (Cpk >= 1.33 sustained 30 days, the Define-gate target). Defensible elimination
   requires the CTQ-1 gate target met, then skip-lot sampling.
5. Refute: processing is only 0.77 d of 18.37 d (4.2%). Removing 11.4 d of WAIT requires no
   additional machine capacity; the only capacity item is the second mill (takt), which is a
   throughput constraint, not a lead-time constraint.

## Court
`python3 courts/court.py` re-derives: wait total, processing total, lead time (vs 18.4 ± 0.05),
PCE, takt 220 s, mill 129/day, 2-mill effective 204 s, C1/C2/C3 and combined lead times,
kanban-variant lead time 5.27 d, Little's-Law counts. Exit 0 = all match; nonzero prints the failing derivation.
