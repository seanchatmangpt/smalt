# Receipt: i29 full-suite pre-gate leg G (`mix test`)

- Date: 2026-10-19
- Subject: `MIX_BUILD_ROOT=_build-ft-fsg mix test` from /Users/sac/smalt (canonical checkout, main @ ab608be)
Context: solo
- Standing: PARTIAL_ALIVE — suite is green solo-per-file, LOAD-class failures under full-suite concurrency; no deterministic failure observed

## Command + output

```
$ MIX_BUILD_ROOT=_build-ft-fsg mix test
# run 1: 1 doctest, 7 properties, 2755 tests, 2 failures (99 excluded) — exit 2
# run 2: 1 doctest, 7 properties, 2755 tests, 4 failures, 1 invalid (99 excluded) — exit 2
```

(An initial warm-up run's exit code was masked by a `| tail` pipeline; runs 1 and 2 above are the counted evidence. Build root `_build-ft-fsg` retained; no edits, no git ops, no build-root deletion.)

## Failure inventory and classification

### Run 1 (2 failures)

1. `test/azsim/dets_recovery_test.exs:237` — DetsRecoveryTest "WasmEngine killed mid-request ... 503":
   `eventually("WasmEngine restarted after kill"): not satisfied within 5000ms (after 30 pass(es)) — last value: :down`
   **LOAD** — passes solo (1 test, 0 failures, 0.4s).
2. `test/semantic_projection_test.exs:555` — Lens7FieldPolicyTest "non-binary field values project nil, well-formed neighbors untouched":
   `semantic projection: vacuous identity under :smalt_resources ("id" = nil) — refusing read`
   **LOAD** — passes solo (4 tests in file:555 context, 0 failures, 0.3s).

### Run 2 (4 failures + 1 invalid)

3-6. `test/ash_extension_test.exs:224, :240, :389, concurrent-churn test` — AshExtensionTest x4:
   `substrate_resource: vacuous identity under :smalt_resources (primary key [:id] = %{"properties" => %{"maxDeliveryCount" => 2}})` — a queue-shaped row (`maxDeliveryCount`) contaminating the shared `:smalt_resources` store surfaced in AshExtension's read. Cross-test store contamination that only appears under full-suite async ordering.
   **LOAD** — file passes solo (14 tests, 0 failures, 1.0s).
7. **invalid**: `Smalt.Chaos.CrashIsolationTest` — setup_all invalidated:
   `eventually("ARM listener answering"): not satisfied within 5000ms (after 28 pass(es)) — last value :retry`
   **LOAD** — passes solo (0 failures, 1.0s).

### AZB-20 lane surfaces

The in-flight AZB-20 edits (`blob_storage.ex`, `cosmos.ex`, `router.ex`, `key_vault_actions.ex`) produced **zero** failures across both runs — no failure in any of those surfaces; every failure is elsewhere (azsim dets recovery, semantic projection, ash extension, chaos crash isolation).

### NEW

Zero NEW (deterministic) failures: every failure from both runs reproduced as PASS when run solo in the same build root.

## Counts

- Total per run: 2755 tests + 1 doctest + 7 properties, 99 excluded (`:stress`, `:amqp_wire` etc.)
- Run 1: 2 failures / 0 invalid / exit 2
- Run 2: 4 failures + 1 invalid / exit 2
- Solo re-verification: 4/4 failing files re-pass (0 failures)
- Verdict: LOAD roster classification; leg G does not surface a NEW or AZB-20-attributable defect. Exit 2 under full-suite load remains a pre-gate caveat for the coordinator.
