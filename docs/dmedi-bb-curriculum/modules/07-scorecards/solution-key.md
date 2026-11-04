# Module 07 — Solution Key

Every number re-derives via `python3 courts/court.py` (exit 0; arithmetic +
structural checks). Derivations shown step by step.

## K1 — Lead-time decomposition (CTQ-2, transactional spine)

Baseline, four stage contributions: queue 11.2 + run 3.1 + move 2.6 + ship 1.5.
Sum: 11.2 + 3.1 = 14.3; 14.3 + 2.6 = 16.9; 16.9 + 1.5 = **18.4 d** — matches the
spine baseline (court `leadtime-baseline-sum`).

Future state: queue 2.5 + run 2.4 + move 0.6 + ship 0.5. Sum: 2.5 + 2.4 = 4.9;
4.9 + 0.6 = 5.5; 5.5 + 0.5 = **6.0 d** <= 7.0 target
(court `leadtime-future-sum`, `leadtime-target-met`).
Stage deltas: queue 11.2 -> 2.5 (-8.7), run 3.1 -> 2.4 (-0.7), move 2.6 -> 0.6
(-2.0), ship 1.5 -> 0.5 (-1.0); total delta 12.4 d, of which the queue stage alone
is 8.7 d = 70% — the leading measure for CTQ-2 must therefore watch queue depth,
not ship date.

## K2 — Cpk yield math (CTQ-1)

Centered-normal defect rate = 2 x Phi(-3 x Cpk).
Baseline: 2 x Phi(-3 x 0.72) = 2 x Phi(-2.16) = **3.077%** (court
`defect-baseline`). Target: 2 x Phi(-3 x 1.33) = 2 x Phi(-3.99) = **0.0066%**
(court `defect-target`). On a 250-piece lot this is 7.7 defective bores per lot ->
0.017 defective bores per lot; the scorecard metric is expressed as defect rate,
not defects per lot, so the target stays legible at any volume.

## K3 — Module-06 tie-outs (the scorecard must not drift from costing)

Values the court string-matches in `worksheets/01-hierarchy.md`: cycle
**13.08 min**, tooling **$3.46**, setup **1.05 h**, ceiling **$28.50**, feed
**630 mm/min**, spindle **11,500 RPM**, baseline cost **$41.80** — each must appear
in the hierarchy (courts `hierarchy-tieout-*`), and "$28.50" must appear in BOTH
the CTQ-3 and Y3 rows (court `hierarchy-no-27.09-vs-28.50-conflict`, count >= 2):
the projected $27.09 is design margin, the ceiling is the metric.

## K4 — Operational-definition completeness (structural key)

15 operational definitions, OD-1..OD-15, each with gauge, sample, frequency, and
calculation non-empty (courts `od-count`, `od-no-empty-cells`, `od-ids`). Worked
check: an OD missing "calculation" leaves an empty cell → the court fails with the
(row, column) index — a metric missing any field is not scorecard-eligible.

## K5 — Data-collection coverage

Every OD id must appear at least once in `worksheets/03-data-collection-plan.md`
with collector/method/system/stratification cells filled
(courts `dcplan-covers-all-ods`, `dcplan-no-empty-cells`). Worked derivation of
the coverage predicate: missing = [o for o in OD-1..OD-15 if o not in plan_text];
court passes iff missing = [].

## K6 — MGPP traceability matrix

Each scorecard metric (OD-1..OD-15 plus Y3) appears exactly once, gate weeks drawn
only from {W5, W9, W15, W21, W26}, owners drawn only from the nine named roles
(courts `mgpp-every-metric-once`, `mgpp-gate-weeks-valid`, `mgpp-owner-is-role`).
16 rows x no duplicates x valid weeks x role owners = the gate-exit authority for
weeks 9/15/21/26.

---

Court: `python3 courts/court.py && echo COURT-PASS` — exit 0, 22/22 checks (the
coordinator audit's "21/21" was stale; re-counted from the actual run: 22 PASS
lines + COURT PASS verdict).
