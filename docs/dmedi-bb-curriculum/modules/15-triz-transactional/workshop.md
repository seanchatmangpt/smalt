# Workshop — Module 15 TRIZ for Transactional Processes

Numeric answers must match `scripts/derive_keys.py`; concept answers must name
a measurement and a reversion trigger.

## W1. Transactional contradiction statements (10 min)

Write each as improving vs worsening with the metric named:

1. "Faster invoice processing makes payment errors."
2. "More supplier documentation slows procurement."
3. "Flexible scheduling erodes preventive-maintenance discipline."

## W2. Adapted-matrix drill (10 min)

Add one new row to the transactional excerpt table: pick an improving and
worsening pair from CPPC's claims or procurement surface, recommend 3
principles from the 40 x 2 index (Module 14), and justify each in one
sentence.

## W3. Claims case replay (15 min)

1. Using the sensitivity formula (hours = 37.5 + (1 - (1-p)^50) * 112.5),
   compute expected audit hours at p = 0.005, 0.01, 0.02, 0.06 by hand, then
   check against the README table.
2. State the p at which the sampled scheme's expected hours first fall below
   100 h/month, and the detection probability there.

## W4. Escaped-defect arithmetic (10 min)

At p = 0.06 with the trigger in place, mean escapes are 0.41/month.
Construct the argument for why escapes are this low even though only 25% is
routinely audited: what exactly prevents a bad claim from escaping when it is
NOT in the sample? Identify the assumption this argument depends on, and what
fails if the assumption breaks.

## W5. Onboarding replay (15 min)

From `datasets/onboarding-durations.csv`:

1. Recompute serial mean/P90 and parallel mean/P90. Check against the
   README's 11.1/12.6 and 7.1/8.5.
2. Design a different parallelization (e.g., manager sign-off moved earlier)
   and compute its mean and P90. State its compliance risk in one sentence
   with a number.

## W6. Post-start check risk (10 min)

With per-check on-time probability 0.9, three post-start checks give
P(all on time) = 0.723. Compute the same probability for 2 and for 4
post-start checks. Then state the rule of thumb this implies for how many
checks may safely move post-start when the day-10 sweep exists — and what the
rule becomes if the sweep is removed.

## W7. Trends audit (15 min)

Pick 4 of the 8 trends from the primer. For each: state where the CPPC
process currently sits and one concrete move to the next state, with the
principle number it embodies.

## See Also

- `solution-key.md`
- `README.md`
