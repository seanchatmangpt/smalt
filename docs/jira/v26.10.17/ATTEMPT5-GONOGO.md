# ATTEMPT5-GONOGO — v26.10.17 court-x2 attempt 5

Date: 2026-10-18. Prepared by the milestone-doc pipeline lane (read-only; no git).
Every claim below cites a receipt on disk at authoring time; re-derive before acting
(RELEASABLE.md convention).

## 1. RELEASE-BLOCKING: court T1/T2/T3 rotating jitter class

Only the court legs' rotating load-face class blocks two-green. Current faces from
the r246 (attempt 4, typed-RED) rotating cluster, with their i22 triage state:

| Face (r246 identity) | Triage receipt | State |
|---|---|---|
| `Amqp.FuzzTest` atom-mint `test/amqp/fuzz_test.exs:561` | `receipts/i22-fuzz-atom-fix.md` | NOT-REPRODUCIBLE stand-down, 3/3 paired green (`:atom_flood` not default-excluded, so the test genuinely ran). No fix applied — no measured failing distribution to calibrate against. Prescribed fix shape recorded for recurrence: delta-over-own-keys or bounded slack from a measured concurrent distribution. Carry-forward falsifier in `receipts/i22-atom-pressure.md`. |
| `ArmErrorCorpusTest` LRO 202/poll (`test/arm_error_corpus_test.exs:274`) | `receipts/i22-error-corpus-lro.md` | HARDENED (PASS): `poll_until_succeeded/2` now deadline-based (5000 ms) with typed flunks; `:lro_delay_ms` pinned 0 in setup with save-prev + on_exit restore. Paired-green 3x + solo green. Face closes only on an attempt-5 corpus-clean run (the receipt's own falsifier). |
| ShaclFuzz admission/corpus rows + TagsNormalization | none | OPEN, untriaged — no receipt names a mechanism or applies a fix. These rows recurred in both r246 legs. |
| atom-table pressure hypothesis for :561 / 1000-PUT sweeps | `receipts/i22-atom-pressure.md` | MEASURED PASS: solo fuzz suite 34/0; WINDOW_DELTA 0 x3 vs limit 1,048,576 — atom pressure is not the mechanism. |

Everything else is READY:

- **B1 / publish-dry**: GREEN 4/4, B1 CLOSED (r244-publish-record.md: hex.build
  PASS, inner-tar keys 0 matches, leak grep 0 hits, error-codes PASS; ex4pm
  26.10.8 hex-only).
- **WO-4 version bump**: rehearsed end-to-end on a scratch materialization
  (WO4-RUNBOOK.md — three files carry the version, exact script exercised; no
  canonical-checkout edits).
- **Fin-sweep**: staged as the wrap stage in `_LANES.md` (I20 court-x2 + fin-sweep)
  and WORK_ORDERS.md; generated-artifact regen has landed receipts
  (i15-mcp-descriptor-regen, i10-sdk-matrix-check). Fin-sweep idempotency is
  asserted by stage design (regenerate-don't-patch generated artifacts), not by a
  standalone receipt — treat as staged, not receipted.

## 2. NON-blocking parks (carry, do not gate attempt 5)

- **Leak-court remainder**: 61 uncovered mutations across 33 files
  (i21-leak-batch5.md; baseline 122 → 101 → 61 over batches 1-5). Gate NOT wired
  into `just court`/`invariant-gates` (i20e-leak-court.md — coordinator owns
  wiring).
- **KD-77 re-witness**: kd_flip mtime-chain fragility; KD-77's witness predates
  edits to `connection.ex` covering a dozen KD ids per one file
  (KD_REWITNESS_DESIGN.md, DRAFT — not implemented, no flips).
- **NOTICE attribution**: publish-advisory; `NOTICE.md` carries no upstream
  license/attribution block (NEXT_WINDOW.md §4; r244 closed the hex leg only).
- **ash_ex4pm sibling pin relax**: blocked on ex4pm .8 availability in the
  sibling checkout; smalt side already hex-only per r244 (NEXT_WINDOW.md §3).
- **FlowCreditTest run-shape flip**: port-key restore pattern landed
  (i21b-leak-wire.md — 4 port keys restored); run-shape flip itself not applied.
- **Atom-table observation**: cross-run accounting flake family
  (docs/STRESS/SUITE_STABILITY.md:158; measurement-fence mechanism typed in
  i22-atom-pressure.md).

## 3. Residual risk quantification for attempt 5

- **Post-fix soak evidence**: warm-up leg 0 on the current tree: 2655 tests,
  0 failures (406.7s) — the window's first zero-failure full-suite pass
  (r246). The clear-race class was absent in 4/4 post-fix full-suite runs
  (r246, citing i21d-store-clear-async). Corpus soak 3/3 (i21-corpus-soak.md).
  No `i22-soak-*` receipt has landed yet; if one lands before the gate, cite it
  here and it strengthens (not weakens) this row.
- **~1-flake/leg history vs post-fix 0-flake runs**: r240 attempts 1-2 and r241
  each tripped exactly one load face in cold run 1, warm run 2 green — a
  ~1-flake/leg structure. Post-repair-wave, the run structure improved to 0
  failures in leg 0 (r246) and the repair receipts (i21-fence10-fix 5x solo
  green + green under artificial load; i21-ets-race-fix; i21-lro-face solo x3 +
  paired; i21-brokerfacade-sweeper 3x solo + 1x paired) each verified under
  load. The residual is the untriaged ShaclFuzz/tags rows above.
- **Frozen-tree protocol as invalidation guard**: r246 voided attempt 4
  because a mid-gate tree edit broke the fresh-subject premise. Attempt 5 runs
  only after: `just quiet-check` GREEN (RELEASABLE row 5), `just quiesce`
  warm-up GREEN, and NO `lib/` or `test/` edits between legs (the `_LANES.md`
  I3 no-re-witness-no-flip rule generalizes: an edit between legs voids the
  attempt regardless of outcome). A warm-up failure is a stop signal, not a
  hurdle (r241).

## Verdict

**GO — conditional, with the exact unmet pre-gate conditions named.**

Unmet conditions (all must hold before the gate launches):
1. `just quiet-check` GREEN on a quiesced machine (currently RED: transient
   foreign-beam/load faces, RELEASABLE row 5).
2. Frozen tree: zero `lib/`/`test/` edits between and during legs.
3. The untriaged ShaclFuzz/tags rows are the accepted residual: if run 1 goes
   RED on them again, the court closes honest typed-RED on that identity —
   attempt 5 is the falsifier run for that face, not a hurdle to clear.

Every other gate row is GREEN or CLOSED on receipts (r244, docs-dod-check 54/54
per RELEASABLE row 4). No NO-GO condition exists: the remaining risk is a loud
typed RED, not a silent regression.
