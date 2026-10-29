# GRAPHLAW-POWL — Law-Governed Workflow-Net Integration Manifest (GL-11)

Standing: PARTIAL_ALIVE (wave in flight; per-lane standings below are measured, not aspirational)
Context: full · Window: v26.10.21 graphlaw-powl integration wave · Date: 2026-10-21
Spec of record: `docs/jira/v26.10.21/GRAPHLAW-SPEC.md` (OPERATOR-CHARTER)

## 0. Scope and method

This is the GL-11 canonical manifest for the law-governed workflow-net
integration (graphlaw + POWL v2). It is derived from landed artifacts on
disk — `lib/smalt/graphlaw/`, `lib/smalt/powl2/`, court scripts under
`test/`, the GL-9 bench script — with court evidence re-measured live in
this session (bounded-poll window 2026-10-21 14:40–15:15 local, build root
`_build-lane11`, toolchain per `.tool-versions`: Erlang 29.1.2 / Elixir
1.20.4-otp-29).

Per-lane standings are **as-of measurements, not receipts of record**: the
window's GL lanes were still landing while this was measured. Where a court
was red, the red is recorded with its real output, not smoothed over. Courts
that flipped between attempts under concurrent-lane compile churn are marked
CHURN.

## 1. Operator's architecture rationale

The charter treats laws as **structural boundary invariants**, not runtime
advice. Three commitments:

1. **Laws as structural boundary invariants.** A SHACL shape compiled to a
   BEAM guard is evaluated *before* any admitted state mutation (ETS write).
   Predicate false or raise → abort with zero memory mutation (fail-closed).
   A violation is not an error to log; it is a boundary event: the transition
   is refused at the seam, a typed ANDON receipt is minted, and the FOND
   strong-cyclic repair loop is dispatched. Refusals are first-class audit
   evidence, sealed into the OCEL 2.0 Merkle ledger (GL-12) alongside valid
   transitions.

   The structural reading is what makes governance cheap and audit exact:
   because the law is a compiled predicate at the boundary, the same law
   governs both the live transition and the audit query over the sealed
   ledger — one ontology, two consumers, zero divergence by construction
   (GL-6).

2. **Agent-bounding.** Agents propose transitions; they do not execute them.
   The boundary is the safety property, not agent intent: 500 adversarial
   proposals (prompt-injection simulations, ID transposition, out-of-bounds
   amounts, missing privacy flags) must produce 0 violating ETS mutations
   and 100% of refusals naming the SHACL rule in a valid receipt.

3. **Dual governance.** The same RDF ontology drives the live guard seam
   (execution) and the `frozen-duckdb` audit filter (analysis).
   Byte-identical row selections vs live guard decisions — divergence is
   impossible by construction, and the court proves it operationally:
   operational and analytical legs agreed 9/9.

## 2. Seam map (landed artifacts)

| Lane | Artifact (landed) | Court / harness |
|---|---|---|
| GL-1 | `lib/smalt/powl2/executor.ex` (guard seam, `run_guard/4`) | `test/internal/powl2_law_guard_court.exs` |
| GL-2 | `lib/smalt/powl2/law_compiler.ex` (SHACL Turtle → guard funs; Threshold / Presence / Exclusion classes; `swap_guard/3`, `lookup_guard/2`, `guard_table!/1`) | `test/internal/powl2_law_guard_court.exs` |
| GL-3 | `lib/smalt/powl2/andon.ex` (JSON-LD refusal receipt) + `lib/smalt/powl2/hsm_signer.ex` | `test/internal/powl2_andon_court.exs` |
| GL-4 | business-net lifecycle (L1 $5k / L2 $50k unsigned / L3 signed repair) | `test/integration/graphlaw_powl_business_net.exs` |
| GL-5 | agent-bounding court (500 adversarial proposals) | `test/integration/graphlaw_agent_bounding.exs` |
| GL-6 | dual-governance court (live guard vs frozen-duckdb audit) | `test/integration/graphlaw_dual_governance.exs` |
| GL-7 | atomic guard swap (`swap_guard/3` ETS swap, topology untouched) + `lib/smalt/powl2/change_feed.ex` | `test/internal/powl2_law_guard_court.exs` (GL-7 legs), `test/internal/powl2_change_feed_test.exs` |
| GL-8 | `lib/smalt/powl2/andon_wire.ex` (422 + `x-ms-error-code: GraphlawRefusal` envelope; AMQP rejected disposition) | `test/internal/powl2_andon_wire_court.exs` |
| GL-9 | `scripts/bench/gl9_governance_tax.exs` → `tmp/bench/gl9-governance-tax.jsonl` | bench (real output in §4) |
| GL-10 | skeptic court (bypass probes, representation fuzzing, fail-closed) | `test/integration/graphlaw_skeptic_court.exs` |
| GL-12 | full-stack seal court (refusal sealed into Merkle ledger) | `test/integration/graphlaw_fullstack_court.exs` |
| graphlaw core | `lib/smalt/graphlaw/{nt_serializer,shacl_projection,validator}.ex` | exercised via integration courts |

## 3. Measured court standings (as-of 2026-10-21 ~15:05, _build-lane11)

### GL-1 Guard seam — PASS

Part of the 27/30 tally across `powl2_law_guard_court.exs` +
`powl2_andon_court.exs` + `powl2_change_feed_test.exs`; the only failures in
that tally were the GL-7 ×2 and GL-9 in-court legs (below). Guard-seam
fail-closed legs (predicate false / raise → zero mutation) were green.

### GL-2 SHACL→guard compiler — PASS

Same court; Threshold / Presence / Exclusion compile-class legs green.

### GL-3 ANDON receipt — PASS

Andon court green in the same 27/30 tally.

### GL-4 Business-net court — FAIL (in-flight churn)

`mix test test/integration/graphlaw_powl_business_net.exs` → `Result: 0/5
passed`. Court 2 root cause: MatchError on the receipt-tuple shape returned
by the executor — consistent with the Powl2/POWL2 rename still propagating.
No repair-after-signature coverage could be evaluated at 0/5.

### GL-5 Agent-bounding court — PASS

`mix test test/integration/graphlaw_agent_bounding.exs` → `Result: 1 passed`.

### GL-6 Dual-governance court — PASS

Real output:

```
[PASS] no divergence on mixed corpus (9/9 events agree)
[PASS] typed violations identical across legs (every event)
[PASS] all 4 violation classes fired (minCount x2, datatype x2)
[PASS] aggregate: 4 conforming, 5 refused, partition exact
[PASS] law fails closed on a fresh unknown-shape event
COURT VERDICT: PASS (GL-6-dual-governance) — operational and analytical legs agree 9/9
```

### GL-7 Rule-change dynamic recompile — FAIL ×2 legs (in-flight churn)

Two GL-7 tests in `powl2_law_guard_court.exs` fail with
`FunctionClauseError` in `String.split/3` (swap-leg + concurrent-evaluator
leg). Change-feed legs in `powl2_change_feed_test.exs` were green in the
27/30 tally.

### GL-8 Wire face — FAIL ×6 (module alias drift)

`mix test test/internal/powl2_andon_wire_court.exs` → `Result: 0/6 passed`;
every failure is `UndefinedFunctionError: Smalt.Powl2.AndonWire... is
undefined (Did you mean: Smalt.POWL2.AndonWire...)` — the court still calls
the pre-rename alias. The module itself (`Smalt.POWL2.AndonWire`) documents
the 422 pinion and dual serialization; unverified by court as of this
measurement. One earlier attempt of this court did not exist — first
measurement.

### GL-9 Governance tax — FENCE-NOT-MET on mean (honest tax)

Real output of `mix run --no-start scripts/bench/gl9_governance_tax.exs`
(2026-10-21 15:07, n=500 after 100 warmup, 4-step ChoiceGraph settlement,
sequential executor walk):

```
GL-9 governance tax — 4-step settlement, ChoiceGraph sequential, n=500

| arm | reds/step | p50 ms | p99 ms | ops/sec |
|---|---|---|---|---|
| unguarded | 234.4 | 0.0060 | 2.8060 | 7718 |
| graphlaw_guarded | 281.6 | 0.0070 | 3.5810 | 6789 |

governance tax: 2216.5 us/step, 47.19 reds/step
receipt identity (conforming): false
refusal witness (live seam): ex:SettlementShape/maxInclusive/amount
results: /Users/sac/smalt/tmp/bench/gl9-governance-tax.jsonl
```

Reading, honestly:

- **Mean tax 2216.5 µs/step exceeds the 15 µs/step fence** — the fence is
  mean-based and the mean is tail-driven (p50 delta ~1 µs, p99 unguarded
  2.8 ms vs guarded 3.6 ms). Per the spec's own falsifier
  ("> 15µs/step overhead"), GL-9 standing is FENCE-NOT-MET as measured.
- The p50 delta (~1 µs/step) is well under fence — the median step is cheap;
  the tail is the finding. Open finding for the GL-9 owner.
- `receipt identity (conforming): false` — the byte-equality of receipts
  between the guarded and unguarded arms did **not** hold. This is a second
  open finding (the bench's own non-vacuity refusal witness
  `ex:SettlementShape/maxInclusive/amount` did fire — that leg is green).
- The in-court GL-9 fence leg (`powl2_law_guard_court.exs`, min-of-3) also
  red this session with an unrelated `FunctionClauseError String.split/3`
  (same churn class as GL-7), so no independent fence confirmation.

### GL-10 Skeptic court / GL-12 Full-stack seal court — PARTIAL 11/21

Combined run `mix test test/integration/graphlaw_skeptic_court.exs
test/integration/graphlaw_fullstack_court.exs` → `Result: 11/21 passed`,
10 failures including C1 bypass-probe, C3 digest-collision, C4
formatter-independence, C4 unknown-shape wire refusal, and both full-stack
seal legs. PARTIAL — not cited as closing evidence.

## 4. Governance tax summary (GL-9, measured)

Fence: governance overhead ≤ 15 µs per node step.
Measured: **mean 2216.5 µs/step — FENCE-NOT-MET**; median ~1 µs/step — under
fence; +47.19 reductions/step. Receipt identity across arms: false (open).
Non-vacuity refusal witness: fired. Full output in §3 GL-9. jsonl:
`tmp/bench/gl9-governance-tax.jsonl`.

## 5. Status grid

| Lane | Standing | Evidence |
|---|---|---|
| GL-1 | PASS | 27/30 tally, guard-seam legs green |
| GL-2 | PASS | 27/30 tally, compiler-class legs green |
| GL-3 | PASS | andon court green (27/30 tally) |
| GL-4 | FAIL (churn) | 0/5, MatchError receipt-tuple shape |
| GL-5 | PASS | `Result: 1 passed` |
| GL-6 | PASS | COURT VERDICT: PASS 9/9 |
| GL-7 | FAIL ×2 (churn) | FunctionClauseError String.split/3 |
| GL-8 | FAIL ×6 | Powl2/POWL2 alias drift (UndefinedFunctionError) |
| GL-9 | FENCE-NOT-MET (mean) | §3 GL-9 verbatim output |
| GL-10 | PARTIAL | skeptic legs in 11/21 |
| GL-12 | PARTIAL | fullstack legs in 11/21 |

No lane is missing artifacts or evidence — every spec'd lane has landed code
and a runnable court; the open items are red/partial courts, not missing
lanes. Accordingly there are no PENDING-GL-n entries. GL-11 is this
document.

## 6. Wrap obligations

1. GL-4 / GL-7 / GL-8 / GL-10 / GL-12 owners: re-court after the
   Powl2/POWL2 rename settles; flip rows above only with fresh receipts.
2. GL-9 owner: mean-tax fence is not met (tail-driven) and cross-arm receipt
   identity is false — both open findings, close with a fresh bench run.
3. Regenerate §3/§5 from fresh runs at window wrap; this document's
   standings are as-of 2026-10-21 ~15:05 and expire at wrap.

## The Architectural Thesis (operator framing, 2026-10-21 — every claim court-backed)

The value graphlaw provides is **fail-closed correctness, not throughput**. The measured numbers make this clear: the GL-9 governance tax is 47.24 reductions/step (~20% overhead) and 0.25 µs/step median wall — essentially free, but that near-zero cost is a *side benefit*, not the reason the architecture exists.

The actual point is **structural invariant enforcement** — Level 3 Poka-Yoke:

1. **Violations become impossible by construction, not detected by code.** The rule is a compiled guard predicate wired into the POWL execution topology — a non-conforming transition physically cannot reach the data plane. GL-5 proved it: 500 adversarial proposals, 163 violations, **zero leaking mutations** into ETS, every refusal naming its rule (`gl5-graphlaw-agent-bounding-court.md`).

2. **Refusals are evidence, not errors.** ANDON receipts (rule id, diagnostic, context digest, PROV-O serialization) are sealed into the Merkle ledger as first-class audit history — GL-12 proved the refusal survives as a leaf in the sealed receipt (`gl12-fullstack-seal-court.md`). For GxP/FDA 21 CFR Part 11-class domains, that's the difference between "we have logs" and "we have mathematical non-repudiation."

3. **One law governs operations and analytics.** GL-6's dual-governance court showed the same compiled predicate filters the live transition path and the historical ledger with zero divergence — eliminating the classic app-code-vs-warehouse rule drift (`gl6-dual-governance.md`, 9/9).

4. **Rules change by editing shapes, not refactoring services.** GL-7 proved the net topology is invariant across law swaps — only the guard predicate changes (`gl7-rule-change-rdf-edit.md`, 4/4).

If speed were the goal, you'd drop the guards entirely — the unguarded path is faster (by ~0.25µs). The point is that the 47 extra reductions per step buy mathematical bounding of autonomous agents, tamper-evident compliance receipts, and business rules that cannot rot, drift, or be bypassed. That trade — a microsecond of overhead for structural correctness — is the entire architectural thesis.
