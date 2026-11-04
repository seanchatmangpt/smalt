# Module 18 Exercises — Monte Carlo Simulation

Run every exercise from the script with the seed STATED in the text: seed
20261105 (the README teaching tables use seed 20261104 — do not copy them,
re-derive). Incantation:

```
python3 modules/18-monte-carlo/scripts/mc_bore_stack.py 20261105
```

1. **E1 — Convergence ladder.** Run the script at seed 20261105 and fill in
   the 1k / 5k / 10k ladder (P0.13 / P50 / P99.87, mu, sigma, Cpk). Track
   P99.87 across the ladder. Does the verdict (Cpk >= 1.33) flip between any
   two ladder steps? Apply the README decision rule and state whether the
   10k verdict may be reported.
2. **E2 — Percentile report vs spec.** From the 10k row, give P0.13 vs LSL
   −25 µm and P99.87 vs USL +25 µm with margins in µm. Compute Cpk from mu
   and sigma by hand and check it against the script's Cpk.
3. **E3 — Interference honesty.** The 10k run reports 0 exceedances. Give the
   rule-of-three 95% upper bound on p_fail, the analytic normal-sum p_fail,
   and explain in two sentences why reporting "p = 0" is a fake answer while
   10,000 draws cannot resolve a 1-in-a-million tail.
4. **E4 — Tornado re-derivation.** The variance share for this additive
   independent model is exact: σi²/Σσ². Compute the four shares by hand from
   the tolerances (σi = tol/3), rank them, and compare to the script's MC
   sample shares at seed 20261105. Explain why the MC shares differ from the
   exact ones (sampling, not model error) and why the ranking cannot change.
5. **E5 — WC / RSS / MC reconciliation.** From the method-comparison block:
   state the verdict and the assumption each method carries (WC: sum of
   tolerances, all-worst-at-once; RSS: independent additive normal; MC:
   same as RSS plus sampling noise). Show the WC band arithmetic and why it
   fails, and why MC Cpk must land near RSS Cpk 1.60.
6. **E6 — Allocation at 24.0 µm.** Using the allocation block, verify by
   hand: (a) proportional scale k = 24/Σt; (b) cost-weighted Lagrange
   lambda = (Σt − budget)/Σ(t_i/c_i); (c) each cost-weighted tolerance
   t_i' = t_i(1 − λ/c_i). Confirm both allocations sum to exactly 24.0 µm
   and explain why spindle_thermal is tightened least in the cost-weighted
   plan (cost weight 4.0).
7. **E7 — Verdict-flip honesty drill.** Hypothetical: suppose the 1k ladder
   step had given Cpk 1.31 and the 5k step 1.36. Per the README decision
   rule, may the 10k PASS be reported? What is the lawful response, and
   what does this rule protect against (seeded-lottery cherry-picking —
   reporting a seed whose ladder happens to clear target)?
8. **E8 — Dataset-law drill.** State in 3 sentences why the seed must be
   written into the exercises, the key, and `datasets/MANIFEST.md` before
   any number is reported: tie your answer to the data-provenance law in
   `RUNNING-CASE.md` (synthetic data, stated seed, keys re-derived from the
   generator — never from a remembered answer) and to what would break if
   the seed were changed silently after keys shipped.

## Timing (per exercise)

E1–E3: 10 min each; E4–E6: 15 min each; E7–E8: 10 min each. Total ~85 min,
consistent with the README activity estimate (~80 min). E6 (Lagrange
allocation) is the hardest; its full arithmetic is worked in
`keys/solution-key.md`.
