# B7 — harness/tiers batch receipt (stress tier + budget gate)

Standing: PARTIAL_ALIVE — all B7 artifacts landed and validated; two
residual faces classified below (both environmental / mid-wave churn,
neither caused by this diff).

Context: solo.

## Landed (stress tier)

1. 15 stress-tag annotations across 12 files (7 `@moduletag :stress`
   files, 8 single `@tag :stress` sites), per stress-tier.md §3. Added
   alongside existing tags. Integrated in checkpoint b2c53b3.
2. `test/test_helper.exs` — `:stress` excluded by default; header comment
   updated from B0's "no test carries the tag" to the landed inventory
   (disclosed edit: B0 owned test_helper per R10; the comment was stale
   after my tags landed).
3. `docs/TEST_ISOLATION.md` §3 — `:stress` row (owner B7; re-enable via
   `mix test --include stress`).
4. `test/stress_tier_census_test.exs` — tier-population fence (>= 20
   stress cases, >= 8 singles, >= 7 moduletag files), untagged so it rings
   in T1. Falsifier witnessed: tag removed -> 1 failure; restored -> green.
5. `justfile.d/28-stress.just` (`test-stress`) + justfile import;
   `scripts/verify_all.sh` stage c2, fail-closed SKIP if recipe missing.
6. Tier exclusion flip witnessed in budget exports: all 36 stress cases
   (15 annotations) have 0 ms ghost lines in the default export vs real
   durations in the `--include stress` export — they do not run in T1.

## Landed (budget gate)

7. `test/support/budget_formatter.ex` — export-only ExUnit formatter (TSV
   `file:line\tms\tCase.test`). Three draft fixes (disclosed per the
   draft's land-lane note):
   - formatters are GenServers cast `{event, payload}`; the draft's
     `handle_event(:test_finished, ...)` clauses never fire. Real clause:
     `handle_cast({:test_finished, %ExUnit.Test{}}, state)`.
   - `test.time` is microseconds (`:timer.tc`); ms = div(time, 1000), not
     the draft's div(time, 100).
   - excluded/skipped tests are not exported (no 0 ms ghosts).
8. `scripts/test_budget_gate.py` — fail-closed (stdlib-only): missing/
   malformed export or manifest, UNMANIFESTED, STALE, BUDGET-UNKNOWN,
   BREACH all exit 1. Draft fix: test-id check is non-empty (draft's `:`
   check rejected the formatter's `Case.test` ids).
9. `justfile.d/28-test-budget.just` (`test-budget-seed` / `test-budget`) +
   import; `scripts/verify_all.sh` stage c3.
10. `docs/jira/v26.10.18/test_budgets.json` — seeded manifest, 2025
    budgets (schema smalt-test-budget/v1), from the default-run export
    with the 36 excluded-case ghost lines pruned (each dropped line
    verified 0 ms in default, >0 ms under `--include stress`).

## Validation (real outputs this session)

- Census fence: `1 test, 0 failures`; falsifier -> `1 test, 1 failure`.
- Formatter smoke (census run): line
  `test/stress_tier_census_test.exs:13  1292  Elixir.StressTierCensusTest....`
  (ms units correct).
- Gate on seeded manifest, real default-run export:
  `PASS budget-gate/fixture:breach (refused)`,
  `PASS budget-gate/fixture:unmanifested (refused)`,
  `== Test Budget Gate == (2025 tests)` / `Gate: PASS`, exit 0. Receipt:
  `tmp/test-budget-gate-receipt.json` (verdict PASS, fixtures [true, true]).
- VACUOUS path witnessed: degenerate manifest (all max_ms 1e9) ->
  `FAIL budget-gate/fixture:breach (ACCEPTED -- VACUOUS GATE)`, Gate FAIL,
  exit 1.
- Tier run (`mix test --include stress` over the 12 tagged files, quiet):
  `252 tests, 3 failures` (exit 2). All 3 are `:lock_drift` — the live
  ggen-marketplace pack at `../ggen-marketplace` computes
  43c15edb... while `ggen_igniter.pack.lock` pins c009b248... (pack-lock
  re-pin needed; environment drift, not this diff — tags-only change).
- Default full run (first pass, pre-f Formatter fixes): 2061 exported
  lines, suite finished; rerun was aborted by a concurrent lane's
  in-flight compile error in `test/auth_enforce_test.exs` (undefined
  `prev_secret`, B5 lane mid-edit) — compile-freeze SLA class, disclosed
  not repaired by me (owner lane active on the file).

## Deviations / coordinator decisions open

- Full-suite x3 seeds gate (master plan step 3) not completed: three full
  runs were destroyed by concurrent-lane mid-flight states (wasm/lro
  compile churn, auth_enforce compile error). Per-file + export-delta
  evidence substituted; coordinator may re-run `mix test` x3 at
  integration.
- Budget gate wired into verify_all as stage c3; note this doubles the
  full-suite cost per verify-all run (draft-accepted trade-off).
- FLAKE_LEDGER F3/F12 close notes not added (ledger file owned by the
  B4/soak lane; tags landed, close note left to integration).
