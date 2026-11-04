# Workshop — Module 14 TRIZ for Product Processes

Show contradiction statements in TRIZ form, matrix lookups re-verified, and
case steps numbered. Numeric answers must match `scripts/derive_keys.py`.

## W1. Contradiction statements (10 min)

Rewrite these vague tradeoffs as improving-vs-worsening parameter pairs (use
the TRIZ parameter names, numbered where the excerpt supports it):

1. "Faster machining ruins the finish."
2. "Adding inspection raises cost."
3. "More gauge instrumentation makes the cell harder to run."

## W2. Matrix lookup drill (15 min)

From the course excerpt in the README: look up (9 vs 28) and (33 vs 28). For
each recommended principle, write one CPPC-specific concept sentence. Then
re-verify both lookups against the excerpt table — a lookup stated from memory
is not admitted.

## W3. Wear-law re-derivation (15 min)

From `datasets/tool-wear.csv`:

1. Compute the regression of `diameter_drift_um` on `parts_since_tool_change`
   (slope, intercept, residual s). Check against the README's 0.0079 / 0.3155
   / 0.56.
2. Predict drift at 500 parts and at 4000 parts.
3. State what drift at 4000 parts implies for the +/- 25 um half-band, and
   what that implies about compensation vs edge replacement.

## W4. Case 1 replay (20 min)

Replay the six steps of case study 1 with a different update interval: if the
offset updates every 50 parts instead of 100, compute the uncompensated lag
and state the tradeoff (update cost vs accuracy) in one sentence each.

## W5. Case 2 critique (15 min)

The skip-lot scheme's risk step shows 333 escapes per 10,000 units if p drifts
to 0.05 undetected. Design the trigger rule that bounds this (state the
detection mechanism, the reversion action, and the audit cadence), and compute
the expected escapes per 10,000 units at p = 0.05 if your trigger samples 1 of
3 lots fully and reverts on any find. Compare with the untriggered 333.

## W6. Principles index deep dive (20 min)

Pick any 5 principles from the 40 x 2 table. For each, write one NEW
transactional example not in the table, for the CPPC claims or onboarding
surface. Principles already carrying CPPC concepts (3, 17, 24, 32) are fair
game but your example must be new.

## W7. Mini case: fixture change vs setup time (15 min)

Construct your own full contradiction walk: improving parameter, worsening
parameter, excerpt lookup, one concept per recommended principle, one chosen
concept with a stated reason. Use a CPPC fixture or setup-change problem (e.g.,
pallet change time vs part-holding rigidity).

## See Also

- `solution-key.md`
- `README.md`
