# BK-PATW — BK-POWLH4 out-of-scope residue closed: 23 misnamed ExUnit courts converted, 10 script courts census-registered

Standing: ALIVE
Context: solo
Build root: `_build-bkpatw`
Date: 2026-10-22
Owner lane: BK-PATW (repo /Users/sac/smalt)

## Verdict

BK-POWLH4's registered residue (36 files in the 1.20 warning list) is closed
typed and mechanically fenced. Final tree:

- `mix test test/integration`: **372 passed, 12 excluded, exit 0**
  (before: 233 passed, 34 files silently not loaded).
- **23 ExUnit-misnamed courts** converted via `git mv` to `*_test.exs`
  (court legs untouched; the only content edits are the typed-skip rework of
  the two distributed-runner courts and the run-line path updates below).
- **10 script courts + 2 fixture generators** registered in the new
  integration-tier census with class + typed-skip reason. The census makes
  the batch-drop hazard loud: any NEW non-pattern file in test/integration
  now trips a population fence instead of landing on the silent warning
  list.

## The 23 conversions (git mv, court legs untouched)

amqp10_bk116_skeptic, amqp10_skeptic_court, bk135r_matter_journal_court,
eventgrid_push_court, graphlaw_agent_bounding, graphlaw_fullstack_court,
graphlaw_powl_business_net, graphlaw_rule_change, graphlaw_skeptic_court,
ja10_transparency_court, ja5_fail_fast_court, ja7_crash_only_court,
peer_two_node_court, powl2_gates_court, scvd_wire_courts,
sql_ingest_mapping_court, sqld5_sql_shape_court, storage_decoupling_court,
trace_session_court, ttv4_journal_boot_replay_court,
ttv5_store_partitioning_court, wasm_real_runner_court, wasm_sandbox_court.

No tail-runner conversion was needed anywhere: all 23 were already ExUnit
sources (the "tail-runner → assertion" pattern from BK-POWLH4 applied to
zero files — the 3 self-exiting courts BK-POWLH4 converted were the entire
self-exiting ExUnit-adjacent set; the remaining misnamed files were ExUnit
bodies with non-matching names).

## Distributed-runner courts: skip made typed, not batch-killing

`peer_two_node_court_test.exs` and `swarm_court_test.exs` exit(:shutdown)
in setup_all when the runner is not distributed — under the batch that
invalidated their tests (368 passed / 4 then 5 invalid witnessed). The skip
is now a module-load-time loud stderr line + a default exclude wired in
`test/test_helper.exs` (conditional on `node() == :nonode@nohost`), because
`ExUnit.configure` is DROPPED by ExUnit.Server once modules register —
witnessed: configure in setup_all (during-run) and in module body (post-
first-registration) both left the tests running into :not_alive. With a
distributed runner (or `--include peer_two_node_court` /
`--include swarm_court`) all legs run verbatim. swarm is BK-ARM3's in-flight
file: the minimal unblock was applied under the compile-freeze SLA and is
disclosed here per the same-checkout fanout law.

## Embedded probe (before/after, _build-bkpatw)

```
# BEFORE (pre-edit baseline, `mix test test/integration`):
Result: 233 passed
warning list: 34 top-level files + 2 fixture generators (36 total) silently
not loaded under the default *_test.exs load filter.

# AFTER (final batch):
exit=0, Result: 372 passed, 12 excluded
warning list: 12 = 10 census-registered script courts + 2 census-registered
fixture generators (census fence is total: warning list == @script_class).

# Census standalone: Result: 3 passed (population fence, reason fence,
# non-vacuity: self-exit rows must contain System.stop/halt; the census
# caught this lane misreading 6 of the 10 scripts as self-exiting when they
# are plain script courts — rows carry the accurate class per file).

# INDIVIDUAL runs, all 23 converted courts, one mix boot each (exit 0 all):
amqp10_bk116_skeptic 2 | amqp10_skeptic_court 7 | bk135r_matter 3 |
eventgrid_push 5 | graphlaw_agent_bounding 1 | graphlaw_fullstack 2 |
graphlaw_powl_business_net 5 | graphlaw_rule_change 4 |
graphlaw_skeptic_court 29 | ja10_transparency 5 | ja5_fail_fast 4 |
ja7_crash_only 6 | peer_two_node 0 passed / 4 excluded (loud typed skip on a
non-distributed runner; BK-ARM6 receipt: 4/4 under a distributed runner) |
powl2_gates 5 | scvd_wire 3 | sql_ingest_mapping 12 | sqld5_sql_shape 14 |
storage_decoupling 1 | trace_session 3 | ttv4_boot_replay 4 |
ttv5_partitioning 4 | wasm_real_runner 7 | wasm_sandbox 6. Sum 132 passed.

# One witnessed transient: BK-41.3 (amqp10_ledger_owner_court_test.exs,
# unowned, green in baseline) failed once mid-wave — :noproc vs :killed
# DOWN-reason race under load; passed on rerun and in both final batches.
# Pre-existing load-sensitivity, registered for its owner lineage, not
# repaired here.
```

## Consumer-path updates (any path change → census rows updated)

- `justfile.d/51-bkvc.just` — ttv4 path → `*_test.exs`.
- `scripts/shim_court/bk135r_scoping_court.sh` — bk135r court path →
  `*_test.exs`.
- `lib/smalt/graphlaw/sql_shape_gen.ex` — docstring court path → `*_test.exs`.

All three landed via coordinator tick checkpoints (fanout law: coordinator
owns git transitions; the renames themselves were staged with `git mv` and
landed in the ticks; census + helper + consumers landed the same way).
Remaining dirty file in the tree is `test/integration/swarm_court_test.exs`
— BK-ARM3's in-flight kc legs, not this lane's.

## Typed findings (disclosed, not repaired here)

- The 2 fixture generators (test/integration/fixtures/{coldchain,
  sqld2}) are registered `:fixture_generator` rows, closing the fence
  total: warning list == census rows exactly.
- sqld2_sql_ingest_court (the 11th script court in BK-POWLH4's count) was
  converted to sqld2_sql_ingest_court_test.exs by the sibling BK-SQLD2X
  lane mid-flight — this receipt covers the 23 + census; 23 + 1 + 10 = 34
  top-level files + 2 generators = the original 36-file residue, fully
  dispositioned.
- Compile-freeze witnesses: lib/smalt/powl2/executor.ex (BK-ARM3,
  unclosed delimiter ~20 min, resolved by owner), swarm_court_test.exs
  (same lane, minimal unblock applied + disclosed). Both resolved; final
  batches green.

## Repro commands

```
MIX_BUILD_ROOT=_build-bkpatw mix test test/integration            # 372 passed, 12 excluded
MIX_BUILD_ROOT=_build-bkpatw mix test test/integration/integration_tier_census_test.exs  # 3 passed
# individuals: for n in <23 names>; do mix test test/integration/${n}_test.exs; done
```

## Files changed (all landed via coordinator ticks; this commit adds the receipt)

- 23× `test/integration/*_test.exs` (git mv from non-pattern names)
- `test/integration/integration_tier_census_test.exs` (new, 12-row fence)
- `test/test_helper.exs` (conditional default exclude for the two
  distributed-runner-only courts)
- `justfile.d/51-bkvc.just`, `scripts/shim_court/bk135r_scoping_court.sh`,
  `lib/smalt/graphlaw/sql_shape_gen.ex` (consumer path updates)
- `test/integration/peer_two_node_court_test.exs` (typed skip),
  `test/integration/swarm_court_test.exs` (disclosed unblock)
- `docs/jira/v26.10.22/receipts/bkpatw-pattern-wave.md` (this receipt)
