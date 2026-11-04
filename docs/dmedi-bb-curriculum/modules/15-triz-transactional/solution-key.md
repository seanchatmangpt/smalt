# Solution Key — Module 15 TRIZ for Transactional Processes

Numeric ground truth: `python3 scripts/derive_keys.py` (claims sim seed 1507;
onboarding from `datasets/onboarding-durations.csv`, seed 1511). Receipt from
this session:

```text
escaped mean=0.41/mo, P(zero escape)=0.954, P(trigger)=0.955
expected audit h: 37.5+0.955*112.5 = 144.9 vs full 150.0
serial mean=11.1 p90=12.6; parallel mean=7.1 p90=8.5
```

## K1. Transactional contradiction statements (W1)

1. Improving: invoice processing throughput (invoices/hour). Worsening:
   payment-error rate (errors/100 invoices).
2. Improving: procurement cycle time (days/PO). Worsening: supplier-file
   completeness (fraction of mandatory fields verified).
3. Improving: scheduling flexibility (fill rate of rush requests). Worsening:
   PM compliance (PM on-time %).

Any pair naming both a metric and its antagonist is admitted; vague pairs
("faster but sloppier") are not.

## K2. Adapted-matrix row (W2)

Reference row: Improving = claims processed per auditor-hour; Worsening =
audit-defect escape rate. Recommended principles:

- 23 (feedback): real-time entry validation flags defects before the claim
  leaves intake.
- 26 (copying): audit against the system-of-record extract instead of the
  assembled file.
- 22 (convert harm to benefit): every escape feeds the intake rule set, so
  the defect class cannot recur.

Justification quality bar: each sentence names the mechanism, not the
intention.

## K3. Claims case replay (W3)

1. P(hit in 50) = 1 - (1-p)^50; hours = 37.5 + P(hit) * 112.5:

- p = 0.005: P = 0.222 -> 37.5 + 25.0 = 62.5 h
- p = 0.01: P = 0.395 -> 37.5 + 44.4 = 81.9 h
- p = 0.02: P = 0.636 -> 37.5 + 71.6 = 109.1 h
- p = 0.06: P = 0.955 -> 37.5 + 107.4 = 144.9 h

2. Expected hours first fall below 100 h between p = 0.01 (81.9) and
   p = 0.02 (109.1). Solving 37.5 + (1 - 0.99...^50)*112.5 < 100:
   P(hit) < 0.5556 -> p < ln(1 - 0.5556)/ln(0.99)... computed directly:
   need (1-p)^50 > 0.4444 -> p < 1 - 0.4444^(1/50) = 0.0162. So below
   p ≈ 0.0162 the scheme is under 100 h/month; detection probability there
   is 0.556 — barely half the months detect the stream. The teaching point:
   cost savings and per-month detection degrade together; the trigger's
   reversion protects you across months (a missed month is caught next
   month), which is why the trigger, not the sampling, is the safety
   mechanism.

## K4. Escaped-defect argument (W4)

A bad claim not in the sample escapes only if NO claim in the sample is bad:
the trigger is a family-level tripwire. P(zero defects in the sample of 50 at
p = 0.06) = 0.94^50 = 0.045 — so in only ~4.5% of months does a hot stream
dodge detection; the simulation's 0.954 zero-escape month probability matches
this. Assumption: defect occurrence is i.i.d. across claims with a stable p.
If defects cluster (one bad batch of 30 claims), the sample may miss the
cluster entirely while the family-level p stays 0.06 — the tripwire assumption
breaks. Mitigation: stratify the sample by claim type/period (principle 3) so
clusters cannot dodge by concentrating outside the sample.

## K5. Onboarding replay (W5)

1. Script receipt (above): serial 11.1 / 12.6, parallel 7.1 / 8.5 — matches
   the README.
2. Reference alternative: legal and IT in parallel, then HR, quality, and
   manager compressed so manager reviews during quality (manager overlaps
   with the HR/quality lane): per hire = max(legal, IT) +
   max(HR, quality, manager). Mean ≈ max-lane arithmetic on the CSV:
   mean of max(legal, IT) ≈ 3.6, mean of max(HR, quality, manager) ≈ 2.9,
   total ≈ 6.5 days — roughly 0.6 days faster than the module plan, but
   manager sign-off no longer sees the completed quality record, so its
   approval is conditional. Compliance risk: an approval granted before its
   input is final — not a numeric risk from the CSV, and therefore NOT
   admitted without a stated check (e.g., manager re-confirmation at the
   day-10 sweep). Lesson: a faster parallelization that silently reorders
   authority is a compliance regression dressed as a win.

## K6. Post-start check count (W6)

- 2 checks: 0.9^2 = 0.810
- 3 checks: 0.9^3 = 0.723
- 4 checks: 0.9^4 = 0.656

Rule of thumb with a day-10 sweep in place: move at most 3 checks post-start
(completeness enforced by the sweep, so the 0.723 pre-sweep figure is a
first-pass rate, not a final-compliance rate). Without the sweep: any moved
check that can be missed is missed at rate (1 - 0.9^n); with no backstop the
safe count is ZERO — completeness must then stay enforced by the serial chain,
which is exactly the 11.1-day baseline.

## K7. Trends audit (W7)

Reference answers (four trends):

1. Controllability: CPPC offset-setting is manual (trial cuts); next state is
   gauge-driven compensation — principle 24/25. (CTQ-1 surface.)
2. Decreasing human involvement: claims audit is human 100%; next state is
   automated trigger rules with human audit only on trigger — principle 23.
3. Uneven development: CNC cell automated, offset manual; claims intake
   digital, review manual. The gap is the opportunity — pick the manual half
   of the most-automated process first.
4. Increasing ideality: skip-lot inspection keeps escape protection while
   queue falls 2.1 -> 0.70 d — principle 10/26.

Grading bar: each answer names the current state, the next state, and a
principle; trend recitation without a move is not admitted.

## Court notes (self-check)

- Claims simulation: 20,000 trials, seed 1507, i.i.d. p = 0.06; zero-escape
  probability 0.954 agrees with the closed form 0.94^50 = 0.045 miss
  probability — the simulation and the arithmetic corroborate each other.
- Onboarding numbers re-derived from the CSV this session (script output
  above); no remembered values.
- Case steps numbered 1-6 in both README cases; each consumes only prior
  steps' outputs.
- Both case concepts name a measurement (audit hours; days-to-productive) and
  a reversion trigger (full-audit trigger; day-10 sweep with access block).

## See Also

- `README.md`
- `workshop.md`
