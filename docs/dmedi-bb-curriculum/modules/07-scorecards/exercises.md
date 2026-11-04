# Module 07 Exercises

Every numeric answer must re-derive from the worksheets under `worksheets/` via
`python3 courts/court.py` (exit 0). Show derivations; the court is the
exit-checked authority — this file only points at the worksheets and the court.

**E1.** Lead-time decomposition (CTQ-2) from `worksheets/01-hierarchy.md` and
the solution key: baseline queue 11.2 + run 3.1 + move 2.6 + ship 1.5 =
**18.4 d** (court `leadtime-baseline-sum`); future 2.5 + 2.4 + 0.6 + 0.5 =
**6.0 d** ≤ 7.0 target (courts `leadtime-future-sum`, `leadtime-target-met`).
Compute the four stage deltas and show that queue alone is 8.7 of the 12.4 d
total delta = 70%. Why must CTQ-2's leading measure watch queue depth rather
than the ship date?

**E2.** Cpk→defect-rate chain: baseline 2 x Phi(−3 x 0.72) = 2 x Phi(−2.16) =
**3.077%** (court `defect-baseline`); target 2 x Phi(−3 x 1.33) =
**0.0066%** (court `defect-target`). On a 250-piece lot, convert both rates to
expected defective bores per lot (7.7 vs 0.017). Why is the scorecard metric
expressed as a defect RATE, not defects per lot?

**E3.** Tie-out integrity: the court string-matches the Module 06 constants —
cycle 13.08 min, tooling $3.46, setup 1.05 h, ceiling $28.50, feed 630 mm/min,
spindle 11,500 RPM, baseline cost $41.80 — inside
`worksheets/01-hierarchy.md` (courts `hierarchy-tieout-*`). Pick any three and
confirm each appears in the hierarchy. Why does the court enforce
"$28.50 in BOTH the CTQ-3 and Y3 rows (count >= 2)" rather than a single
occurrence?

**E4.** Operational-definition completeness (structural): the court requires
exactly 15 rows OD-1..OD-15 in `worksheets/02-operational-definitions.md`,
zero empty cells (gauge, sample, frequency), each covered by the data
collection plan in `worksheets/03-data-collection-plan.md` (courts
`od-count`, `od-no-empty-cells`, `od-ids`, `dcplan-covers-all-ods`). Draft one
new operational definition for "queue depth" consistent with E1's 8.7 d queue
delta, listing all four required fields. Which court would fail if the gauge
field were left blank?

**E5.** MGPP traceability from `worksheets/05-mgpp-traceability.md`: every
metric maps to exactly one gate week (court `mgpp-gate-weeks-valid`) and every
owner is a role, not a person (court `mgpp-owner-is-role`). Give two reasons a
named individual as owner breaks the scorecard when staffing changes, and one
reason a metric with no gate week is a silent omission at the Define gate.

**E6.** Leading vs lagging from `worksheets/04-leading-lagging.md`: classify
each of (a) baseline Cpk 0.72, (b) queue depth, (c) ship-date adherence,
(d) tooling cost per part, as leading or lagging for CTQ-1/CTQ-2. Defend each
classification using the deltas in E1/E2 — which pair would the court's
`hierarchy-tieout-*` checks refuse to let drift apart?
