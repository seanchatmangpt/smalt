# Module 17 Exercises — Statistical Tolerance Stack

All exercises re-derive from `datasets/gimbal-bore-stack-parameters.csv`
(MANIFEST-registered) and the seeded MC at seed **20261104**. Every number
you report must come from an executed computation — the court or the
documented heredoc in `keys/solution-key.md` — never from memory. Run from
the curriculum root:

```
python3 modules/17-statistical-tolerance/court.py; echo RC=$?   # RC=0 required
```

1. **E1 — Three methods, one stack.** From the stack CSV (4 contributors,
   net mean +1.0 µm, spec ±25 µm): compute the worst-case band, the RSS σ
   and 3σ band, and reconcile against the seeded MC 10k run (P0.13 −13.97,
   P99.87 +16.60, Cpk 1.588). Confirm WC [−28, +30] → FAIL, RSS σ 5.000 /
   Cpk 1.60 → PASS, and state the assumption each method carries. Then
   explain why RSS and MC agree here (additive independent normal is
   exactly RSS's model) and which suspect to check first when they disagree
   on another stack.
2. **E2 — Cpk by hand on both methods.** Verify by hand: Cpk_RSS =
   min(25 − 1, 1 + 25)/(3 × 5.000) = **1.60** and Cpk_MC = min(25 − 1.029,
   1.029 + 25)/(3 × 5.033) = **1.588**. Confirm both clear the 1.33 target
   and |ΔCpk| = 0.012 sits inside the court's reconciliation band ±0.05
   (σ band: |5.033 − 5.000| = 0.033 ≤ 0.25). State why the court pins BOTH
   methods to tolerance instead of trusting one.
3. **E3 — Interference honesty.** Derive p_fail = (1 − Φ(4.80)) +
   Φ(−5.20) ≈ **8.9e-07** analytically (σ 5.000, mean +1). Explain why 0
   exceedances in the 10k MC cannot confirm it (rule-of-three bound
   3/10,000 = 3.0e-04, ~340× above the analytic value) and what run count
   you would need before a zero-exceedance MC result becomes informative
   at the 8.9e-07 scale.
4. **E4 — Allocation decision.** Budget 24.0 µm. Re-derive both allocations
   from the CSV: proportional k = 24/29 = **0.8276** → (8.28, 6.62, 4.97,
   4.14), RSS σ 4.14; cost-weighted λ = 5/18.333 = **0.2727** → (7.27,
   7.45, 5.18, 4.09), RSS σ 4.11. Both hit WC 24.0 exactly. Write the
   decision sentence: which plan do you take to the customer and why (same
   budget, σ 4.11 vs 4.14, cheap bore op absorbs −27% while the expensive
   thermal loop moves −7%).
5. **E5 — Staleness drill.** A vendor report claims the stack sigma is
   4.17 µm. Compute the Cpk that 4.17 implies (0.016/(3×4.17/1000) mm =
   1.28) vs the derived 1.60, and confirm the court's two refusal checks
   fire (`stale_sigma_refused_data`, `stale_sigma_refused_coherence`).
   Write the one-sentence data-provenance rule this encodes: numbers that
   survive adjudication as STALE do not re-enter a new module as pins.
6. **E6 — Court non-vacuity.** Run the court and its mutation arm:

   ```
   python3 modules/17-statistical-tolerance/court.py --mutate; echo RC=$?   # RC=1
   ```

   Confirm PASS at RC=0 and MUTATION DETECTED at RC=1 (`RSS Cpk pinned at
   1.33 vs derived 1.6000`). Explain in 2 sentences why a court that cannot
   be made to fail is not evidence, tying back to the Module 12
   adjudication and `RUNNING-CASE.md`.
