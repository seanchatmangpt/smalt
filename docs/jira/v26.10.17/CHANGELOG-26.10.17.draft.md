# DRAFT — GATED ON TWO-GREEN (do not insert into CHANGELOG.md until the bump lane lands after two-green)

The `## [26.10.17]` section text below is prepared for insertion into
`CHANGELOG.md` by the bump lane. It is NOT landed. Version on disk stays
`26.10.16` (`mix.exs:4`) until WO-4 runs post-two-green. Standing at draft
time: **TYPED-RED** (court-x2 gate closed honest RED after attempts 1–3;
attempt 4 queued post-i21 — see `docs/jira/v26.10.17/FINAL.md`).

---

## [26.10.17] - <date> — UNRELEASED

Court-RED-closure wave over the v26.10.16 surface; no new planes. Status:
**TYPED-RED** — court-x2 gate closed honest RED after attempts 1–3
(receipt chain `receipts/r240-court-x2-attempts12-typed-red.md` →
`receipts/r241-court-x2-attempt3-typed-red.md`); **35 completed gate
invocations, 0 two-green** (32 prior + 3 this window); attempt 4 queued
after the i21 repair wave. Every tripped face is solo-green on the same
tree; fence 10 (`test/affidavit_wasm_failclosed_test.exs:502`) was
upgraded to **PERSISTENT-FLAKE** (repeats under court load, solo-green)
and is now repaired (see Fixed, fence 10). Terminal witness:
`docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md`;
standing flips only on a green two-run receipt (see
`docs/jira/v26.10.17/FINAL.md`).

### Fixed

- **Fence 10 PERSISTENT-FLAKE, repaired deterministically**
  (`test/affidavit_wasm_failclosed_test.exs:502`): the bogus-path refusal
  assertion's 100 ms wall-clock bound conflated scheduler jitter with the
  regression class. Bound moved to **250 ms — the engine's own bounded
  start-retry delay** (`@start_retry_delay_ms 250`,
  `lib/smalt/affidavit/wasm_engine.ex`), making the assertion exactly
  "zero leaked retry sleeps": one leaked sleep guarantees >=250 ms (RED),
  while clean refusals are single-digit ms solo and 129 ms witnessed
  worst-case under load. 5x solo green + green under artificial load
  (`receipts/i21-fence10-fix.md`).
- **EgressDispatchTest setup ETS race** (`test/egress_dispatch_test.exs`
  setup only): a sibling suite's private-tree teardown can kill the named
  ETS tables in the window between `ensure_store_up()` and `Store.clear/0`
  (`ArgumentError: table identifier does not refer to an existing ETS
  table`). Added bounded typed retry `resilient_clear/1` (50 retries,
  10 ms backoff; re-runs `ensure_store_up()` then `Store.clear/0`;
  rescues only the exact dead-table `ArgumentError`; past the bound it
  raises loudly). Test-side only, no product code touched
  (`receipts/i21-ets-race-fix.md`).
- **LRO op-record store miss** (`test/lro_test.exs:543`): fixed
  sleep + single sweep + hard assert replaced with
  `sweep_until_terminal/3` — a 5 s bounded retry that loops raw store
  reads of all 500 ids against `Sweeper.sweep_now()` per pass and flunks
  with a TYPED message naming the offending record keys and rid. 33/0
  solo x3 (`receipts/i21-lro-face.md`).
- **broker_facade Sweeper-whereis-nil seed face**
  (`test/amqp/broker_facade_test.exs` setup/teardown): when another
  module's private-tree teardown has stopped the shared Sweeper, the test
  now boots a fresh ExUnit-managed `start_supervised!(Sweeper)` instead
  of `:sys.suspend(nil)`. 3x solo + 1x paired green
  (`receipts/i21-brokerfacade-sweeper.md`).
- **EventGrid eg1_publish readback merge-order divergence**:
  `event_stream.ex` + `arm_gateway/router.ex` re-domained onto the shared
  EventStream counter. Receipt: `receipts/i20f-egmerge-fix.md`; draft KD
  row retired as FIXED.
- **DetsMirror contention window**: `DetsMirror.sync/1` GenServer.call
  timeout 5 s → 30 s with the contention-mechanism citation
  (`receipts/i20b-contention-mechanism.md`).
- **Test-isolation leaks**: honest first-run leak court
  (`gates/test_isolation_leak_gate.py`,
  `receipts/i20e-leak-court.md`) — `verdict=FAIL-TREE-LEAKS
  offenders=56`, non-vacuity fixtures 3/3 REFUSE; followed by the i21
  remediation batches 1–3 (env-restore discipline,
  `receipts/i21-leak-batch1.md`..`batch3.md`): leak court now reports
  **101 uncovered mutations across 47 files, delta 122 → 101 (−17.2%)**
  (`receipts/i21-leak-court-delta.md`). Gate still exits 1 by design
  until the remainder clears; wiring into `just court` is next-window
  work.

### Added

- Harness mechanisms (`7b42734`): `just quiet-check` / `just quiesce`
  (idle-machine + warm-up gates exercised for court attempt 3), the
  leak-court recipe, the NO-CONTEXT flag, rewitness, wt-scratch,
  corpus-soak. Standing law: `docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md`
  (receipt-cited counts are re-read from the receipt at use time).

### Changed

- **Blob pagination perf budget 110 → 180 ms**
  (`test/data_plane/blob_hardening_test.exs` pagination contract):
  min-of-3 → min-of-5 reps, with the regression-detection math moved into
  the block comment — the old 110 ms budget flaked even on a quiet
  machine (128 ms witnessed quiet); loaded runs 138/119/170; the
  revert-class (full-value materialization) estimate is ~205 ms quiet,
  and 300 ms would NOT fence it. 180 ms separates clean path from the
  revert class (`receipts/i21-blob-budget.md`).
- **Churn test budget 300 s → 600 s** (`test/store_dets_test.exs`
  timeout tag, with comment citing the measured churn profile)
  (`receipts/i21-churn-budget.md`).
- Compliance corpus: first green witness — `mix test test/corpus_test.exs`
  → **26 tests, 0 failures** (2026-10-17), with per-file ever-green first
  witnesses (e.g. C6 OAuth 18/0, `receipts/i20h-c6-first-witness.md`).
- **Publish blocker B1 CLOSED** (`receipts/r244-publish-record.md`):
  ex4pm 26.10.8 published to hex; smalt `mix.exs` flipped hex-only
  (`{:ex4pm, "~> 26.10.8"}`, override dropped; `ash_ex4pm` stays
  dev/test-only optional); `mix.lock` resolves ex4pm 26.10.8 from
  `:hexpm`; `publish-dry` **4/4 PASS** (hex.build, inner-tar keys grep,
  packaged-set leak grep, error-codes check). Publish standing is no
  longer publish-blocked; the sole remaining release gate is court-x2
  two-green.
- Honest court chain: 35 completed court-x2 invocations, 0 two-green
  (32 carried from the v26.10.16 terminal ledger + 3 this window's
  fix-and-retry attempts — the ledger is carried forward, not reset);
  attempt 4 queued post-i21.
- KD register: 95 rows KD-01..KD-97, **39 CLOSED / 55 OPEN**
  (canonical recount in `docs/jira/v26.10.17/COUNTERS.md`); KD-97 minted
  and flipped CLOSED-SIMULATED this window. KD-77 flip remains OPEN
  blocked on a PASS re-witness.
