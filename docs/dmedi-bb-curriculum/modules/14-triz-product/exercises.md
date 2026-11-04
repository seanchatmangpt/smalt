# Module 14 Exercises — TRIZ for Product Processes

Complete the workshop (`workshop.md`) sections W1-W7, then do the following.
All numbers re-derive from `datasets/tool-wear.csv` via
`scripts/derive_keys.py` (seed 1419, 40 rows, run from the
`docs/dmedi-bb-curriculum` root). Pinned keys: slope 0.0079 um/part,
intercept 0.3155 um, s_res 0.56 um; wear at 4000 parts (32.59 um) exceeds
the +/- 25 um half-band. Matrix lookups are course-excerpt pins:
(9 vs 28) -> 3, 17, 24, 32; (33 vs 28) -> 24, 26, 32.

1. **E1 — Contradiction re-formation.** Rewrite workshop W1's three vague
   tradeoffs as improving-vs-worsening pairs in TRIZ parameter names
   (numbered where the excerpt supports it). Check against solution-key K1:
   9 Speed vs surface finish; coverage vs 32 cost; 27 Reliability vs 33 Ease
   of operation. An answer that keeps the vague form is not admitted.
2. **E2 — Lookup re-verification.** Re-verify both workshop W2 lookups
   against the README excerpt table — a lookup stated from memory is not
   admitted. For each of the six recommended principles (3, 17, 24, 32;
   24, 26, 32), write one CPPC-specific concept sentence, then check your
   sentences differ by surface where the same principle appears twice
   (solution-key K2).
3. **E3 — Wear-law re-derivation.** Run
   `python3 modules/14-triz-product/scripts/derive_keys.py` and confirm
   slope 0.0079 / intercept 0.3155 / s_res 0.56. Then compute by hand:
   drift at 500 parts (3.94 um) and 4000 parts (31.6 um from the fit), and
   state what 31.6 um vs the 25 um half-band implies for compensation vs
   edge replacement (compensation re-points the reference; it does not
   repeal wear).
4. **E4 — Interval tradeoff.** Replay workshop W4's case-1 replay at a
   50-part update interval: lag = 0.0079 x 50 = 0.395 um, half the 100-part
   lag. State the decision rule (largest interval whose worst-case lag stays
   under 10% of the remaining half-band after gauge error) and show why
   100 parts already satisfies it, so 50 parts is not justified.
5. **E5 — Trigger bounding.** Design your workshop W5 trigger, then bound
   it: at p = 0.05 with 1-of-3 sampling + automatic reversion, a sampled lot
   of 200 detects drift with probability 1 - 0.95^200 ~ 0.99996, so escapes
   are bounded by the skipped lots ahead of the first sample (2 x 200 x 0.05
   = 20 vs the untriggered 333 per 10,000). State why the reversion must be
   automatic — a trigger requiring human judgment is the failure mode.

## See Also

- `workshop.md`
- `solution-key.md`
- `datasets/tool-wear.csv`
- `scripts/derive_keys.py`
- `../13-concept-generation/exercises.md` (same CPPC spine)
