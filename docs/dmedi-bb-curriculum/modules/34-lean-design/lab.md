# Module 34 Lab — Flow-Redesign the DMEDI Program

**Data**: `data/gate-review-waits.csv` (authored census of the pinned 26-week program; no RNG).
**Deliverable**: receipt with all numbers re-derived via `python3 courts/court.py`.

## Part 1 — Baseline flow metrics
1. Verify the census sums to 130 working days.
2. Total work, internal wait, gate wait; flow efficiency.

## Part 2 — Wait ranking
3. Rank the 10 wait pools (5 internal + 5 gate) by size. Which two phases hold half the wait?
4. Compute flow efficiency excluding gate wait from "wait" (i.e., treat gate wait as value-added
   decision time) — does the conclusion change?

## Part 3 — Redesign scenario F
Apply: gate wait 3 -> 1 d at all five gates; internal waits 4->2, 3->1, 5->2, 6->3, 5->2.
5. New totals, new program length in days and weeks, calendar saved.
6. New flow efficiency.
7. Sensitivity: if ONLY the gate cadence changes (internal waits unchanged), what is saved?

## Part 4 — Flow-checklist audit
8. For each of the 6 checklist items in the slides, answer for the CPPC program AS PINNED
   (gates at weeks 5/9/15/21/26). Item-by-item: pass/fail, with evidence.
