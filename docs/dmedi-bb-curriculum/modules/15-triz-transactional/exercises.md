# Module 15 Exercises — TRIZ for Transactional Processes

Complete the workshop (`workshop.md`) sections W1-W7, then do the following.
All numbers re-derive from `datasets/onboarding-durations.csv` via
`scripts/derive_keys.py` (claims sim seed 1507; onboarding seed 1511, 12
hires x 5 stages). Pinned keys: serial mean 11.1 d / P90 12.6 d vs parallel
7.1 d / 8.5 d; claims sensitivity hours = 37.5 + (1 - (1-p)^50) x 112.5;
escape mean 0.41/mo at p = 0.06 with trigger, P(trigger) 0.955.

1. **E1 — Metric-named contradictions.** Rewrite workshop W1's three vague
   tradeoffs with both a metric and its antagonist named (solution-key K1).
   Check yours against the reference pairs (invoices/hour vs errors/100;
   days/PO vs supplier-file completeness; rush fill rate vs PM on-time %).
   Vague pairs are not admitted.
2. **E2 — Matrix row design.** Build your workshop W2 adapted-matrix row,
   then audit each justification against the quality bar in solution-key
   K2: every sentence names the mechanism, not the intention. Compare with
   the reference row (23 feedback / 26 copying / 22 harm-to-benefit) —
   your principles may differ but must come from the Module 14 40 x 2
   index.
3. **E3 — Sensitivity re-derivation.** Compute by hand at p = 0.005, 0.01,
   0.02, 0.06: P(hit in 50) = 1 - (1-p)^50 and hours = 37.5 + P x 112.5
   (62.5 / 81.9 / 109.1 / 144.9 h). Then solve the workshop W3.2 threshold:
   hours < 100 requires (1-p)^50 > 0.4444, i.e. p < 0.0162 — state the
   detection probability there (0.556) and the teaching point (cost savings
   and per-month detection degrade together; the trigger, not the sampling,
   is the safety mechanism).
4. **E4 — Escape-argument audit.** For workshop W4: mean escapes 0.41/mo at
   p = 0.06 with only 25% audited. Name the assumption (an escape found by
   the trigger reverts the stream; unsampled claims are protected only by
   the automated trigger's reversion, not by the sampling itself) and what
   fails if it breaks (human-gated reversion — the 333-class leak of the
   Module 14 W5 failure mode reappears transactionally).
5. **E5 — Onboarding replay.** Run
   `python3 modules/15-triz-transactional/scripts/derive_keys.py` and
   confirm serial 11.1/12.6 and parallel 7.1/8.5 from
   `datasets/onboarding-durations.csv`. Then compute your own W5.2
   alternative parallelization's mean/P90 and state its compliance risk in
   one sentence with a number (e.g., sign-off before legal review shifts
   rework to the serial tail — quantify the P90 delta).
6. **E6 — Post-start check rule.** For workshop W6: with per-check on-time
   0.9, verify 0.9^3 = 0.723, then compute 0.9^2 = 0.81 and 0.9^4 = 0.656.
   State the rule of thumb this implies with the day-10 sweep as backstop
   (each added post-start check multiplies the miss probability by 0.1;
   3 checks cost ~28% on-time), and what the rule becomes if the sweep is
   removed (no backstop — any single miss is a permanent escape, so the
   count must go to zero or the checks move back pre-start).

## See Also

- `workshop.md`
- `solution-key.md`
- `datasets/onboarding-durations.csv`
- `scripts/derive_keys.py`
- `../14-triz-product/exercises.md` (trigger/reversion thread)
