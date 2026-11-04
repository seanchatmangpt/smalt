# Module 42 Exercises

1. **Vehicle choice.** Your Develop phase predicted Cpk 1.50 on a NEW 3-axis mill program. A teammate proposes "a 20-piece functional prototype, then ship". Name the question that question fails to answer, and the cheapest vehicle that answers it.
2. **Lot size.** If the Develop prediction were Cpk 1.45 instead of 1.50 (same gate LCB ≥ 1.33, z = 1.645), what is the minimum measured n? Recompute the pilot lot under the 40-pieces/day measurement structure. (Answer: n = 220 → 240 pieces = 6 days.)
3. **Test naming.** For each criterion below, name the missing statistical content: (a) "Cpk looks good after the pilot"; (b) "Ra stayed about the same"; (c) "scrap was low".
4. **Falsifier check.** State, in one sentence each, how each of the four exit criteria in the lab could FAIL (what observation would exit nonzero).
5. **Vacuity hunt.** A pilot report says "30-day run completed successfully, no issues observed". List the four receipts it must additionally carry to pass the Module 42 court.
6. **Binomial logic.** Why is the scrap exit "X ≤ 14 of 4500" and not "X < 15"? Verify numerically that X = 14 gives a Clopper–Pearson 95% upper bound of 0.49% and X = 15 gives 0.51%.

## Timing (per exercise)

(10 min) each for exercises 1–6; total 60 min, consistent with the slides-outline
estimate (exercises 1.0 h). Exercise 6 (Clopper–Pearson check) may run over; the
binomial bound arithmetic is in `keys/solution-key.md`.
