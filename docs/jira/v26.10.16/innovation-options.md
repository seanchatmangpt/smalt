# Innovation Options — v26.10.16 wrap → next window

Method: innovation-explorer skill, option-generation + skeptical scoring,
(ALIVE × gain) / cost. Landed by the coordinator from the skill lane's report,
2026-10-16. Coordinator corrections to the lane's premise-audit are marked ⚠.

## Premise audit (with coordinator corrections)

1. ⚠ **BLAKE3 chain: ALIVE in ~/affidavit.** The lane scored it 0.10 ALIVE
   claiming `chain.rs` is SHA-256 Merkle — falsified by direct read:
   `~/affidavit/src/chain.rs` is a rolling BLAKE3 chain (`chain_hash_n =
   blake3(prev ‖ canonical_bytes(event_n))`, genesis-seeded; handlers.rs uses
   blake3 throughout). The lane confused `src/` with `affidavit-core/src/`.
   The smalt-side audit ("smalt pack lock is SHA-256") remains true — the
   migration option is real, cost unchanged.
2. **release-receipt/v1**: no on-disk referent — correct; it is a mint
   (schema exists only in `~/affidavit/release/v26.9.25/receipts/brce-ledger.json`
   as an instance, not a smalt schema). ALIVE low for code reuse; high as a
   wrap-time mint.
3. **ML-DSA PQC**: honest GAP_TYPED, NOT_CLOSED; live surface is the
   `:PQC_NOT_PROVISIONED` typed refusal. Correct.
4. **XES**: parse-only in ex4pm; no emitter on either side. Correct.

## Ranked options (score = ALIVE × gain / cost)

| # | Option | Lens | A | G | C | Score |
|---|---|---|---|---|---|---|
| 1 | Registrar flip pass KD-77 (PASS re-witness first) + KD-78 | external-gap | .85 | 2 | 1 | 1.70 |
| 2 | AshAffidavit.Refusal ↔ smalt court/OCEL typed-refusal mapping (table-driven, witness-tested) | cross-repo | .80 | 4 | 2 | 1.60 |
| 3 | QueueDescription probe legs (`getQueueRuntimeProperties`, PUT round-trip) | capability | .90 | 3 | 2 | 1.35 |
| 4 | gap-census exclusion one-liner (fold into docs lane) | tooling | .95 | 1 | 1 | 0.95 |
| 5 | release-receipt/v1 mint (DMEDI Define/Measure first) | ambition-gap | .35 | 4 | 2 | 0.70 |
| 6 | ex4pm OCEL emitter conformance sweep (14 pending matrix items) | capability | .60 | 2 | 2 | 0.60 |
| 7 | XES emit leg (conventions derived from ex4pm xes.ex parser) | cross-repo | .55 | 3 | 3 | 0.55 |
| 8 | ML-DSA-65 verify-only behind `:PQC_NOT_PROVISIONED` (SUPERSEDED 2026-10-17: upstream `a8c3c2b` ships `pqc_verify`/`pqc_assemble` with ML-DSA-65; artifact re-pinned `b3cf38ba…`; forge court witnessed, KD-89 CLOSED-WITH-RECEIPT — receipts/kd89-ml-dsa-closure.md; this option is now LANDED, not blocked) | ambition-gap | .40 | 5 | 5 | 0.40 |
| 9 | Wire-replay/tf-wire-ladder receipts | external-gap | .45 | 3 | 4 | 0.34 |
| 10 | BLAKE3 chain migration for pack-lock/evidence integrity (real after correction; SMALT pack lock is SHA-256 today) | ambition-gap | .50 | 2 | 3 | 0.33 |

## Top 3 detail

1. **Registrar flip pass** — KD-77 path: correct the locked-survivor premise
   in test_w3_session_ops.py, re-witness PASS, `kd_flip.py --apply`. KD-78:
   fence exists (200/0), flip is registrar-owned bookkeeping.
2. **Typed-refusal mapping** — `ash_affidavit/lib/ash_affidavit/refusal.ex`
   codes ↔ smalt `court_emit`/deviation_admission; must be table-driven +
   witness-tested, not convention-drift.
3. **QueueDescription probe legs** — gaps enumerated with typed soft spots
   (getDate throw; PUT persists only 4 fields); close conditions pre-written.

## Rejected / parked

- ML-DSA full provision: DMEDI pass first, not a direct build.
- release-receipt/v1: Define/Measure pass to mint the schema first — though
  as a WRAP-TIME artifact it can be minted THIS wrap (see wrap sequence).

## Post-integration refresh (innovation-explorer, skeptical rescore, 2026-10-16)

Rescored against post-integration reality. Scores (ALIVE × gain) / cost,
EXPLORE-mode only — candidates, not commitments.

| # | Option | A | G | C | Score | Δ |
|---|---|---|---|---|---|---|
| 1 | Registrar flip pass KD-77 (PASS re-witness first) + KD-78 | .85 | 2 | 1 | 1.70 | unchanged |
| 2 | AshAffidavit.Refusal ↔ smalt court/OCEL typed-refusal mapping | .80 | 4 | 2 | 1.60 | still #2 |
| 3 | QueueDescription probe legs | .90 | 3 | 2 | 1.35 | unchanged |
| 4 | ggen projection wiring (defaults → provider matrix → cascade) | .85 | 3 | 2 | 1.28 | re-listed |
| 6 | gap-census exclusion one-liner | .95 | 1 | 1 | 0.95 | folded into docs lane |
| 5 | In-process blake3 NIF | .80 | 2 | 3 | 0.53 | ↑ from 0.33 — KD-90-pinned |
| 9 | ex4pm OCEL emitter conformance sweep | .60 | 2 | 2 | 0.60 | unchanged |
| 10 | XES emit leg | .55 | 3 | 3 | 0.55 | unchanged |
| 8 | release-receipt/v1 mint | .35 | 4 | 2 | 0.70 | unchanged |
| 7 | wasmex engine-pool (mirror AshGraphLaw.Pool) | .50 | 3 | 4 | 0.38 | NEW — park until pool churn recurs |
| 12 | Wire-replay/tf-wire-ladder receipts | .45 | 3 | 4 | 0.34 | unchanged |
| 11 | ML-DSA-65 verify-only | .10 | 5 | 5 | 0.10 | hard-blocked upstream |

Dispositions: c11 graduation DONE (removed from table). ML_DSA65 demoted to a
parked external dependency (affidavit-side WO; KD-89 close is the trigger).
Recommended next: option 1 (flip pass), then option 5 (blake3 NIF — KD-90
gives a pre-written close condition and a pinned bench baseline).
