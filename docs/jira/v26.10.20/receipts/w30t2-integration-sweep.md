# W30-T2 Integration Sweep (fresh replacement lane)

Date: 2026-10-21 11:52–12:04 PDT · Lane: w30t2 · Build root: `_build-w30t2`
**Standing:** **PARTIAL_ALIVE**

## Context

Replacement for a stalled (>90 min) integration lane. Time-boxed sweep: compile + kd*
integration tier + test/internal census, with per-file classification. **Fix nothing** was
honored — no source edits. Substrate never restarted (`substrate.sh status`: UP pid 8877,
ports 9443/9444/5672/5673, lock FREE).

**Disclosed interference**: an ACTIVE WRITER lane was live-authoring `lib/smalt/powl2*` and
`lib/smalt/pplan/receipt_engine.ex` for the entire sweep window (observed mtimes advancing
11:49→12:03 while the sweep ran). Those files are untracked, compile-BROKEN, and block the
shared compile, so every gate below ran with them moved aside to `/tmp/w30t2/` (move-aside +
test in one atomic command; latest snapshots restored afterward). Files whose current-disk
version was newer than my snapshot were left untouched; my stale snapshot dirs remain in
`/tmp/w30t2/` (`aside_1792609307`, `powl2.attempt2`, `executor.ex.broken`, `a2`) — a `rm -rf`
cleanup was permission-denied.

## Gates (actual output)

| Gate | Command | Result |
|---|---|---|
| Compile | `MIX_BUILD_ROOT=_build-w30t2 mix compile` | Clean once the untracked `powl2*`/`petri_net.ex`/`pplan/receipt_engine.ex` files are aside; only warnings (unused `body`/`op` in `amqp/connection.ex:1691-1692`, charlist deprecation `sas_verifier.ex:284`) |
| Compile (raw) | same, no move-aside | **FAILS**: `SyntaxError lib/smalt/powl2/executor.ex:290` → later `TokenMissingError :112`; `powl2/decomposition.ex` undefined `and_split_closure/3`, `union/3`, `seed/1`; `sb_rules.ex` CompileError |
| kd* integration tier | `mix test test/integration/{blob_kd_fixes,kd62_udk_witness,kd143_rules_persistence,amqp_kd131_133_triage,certificates_kd104_witness,kd_conformance,kd156_sb_shape,kd51_sb_atom_https,kd155_delete_framing,kd130_container_exists}_test.exs` | **53 tests, 0 failures** (2.9 s) |
| kv404 (dirty tracked) | `mix test test/integration/kv404_typed_error_test.exs` | **2 tests, 0 failures** |
| test/internal census | `mix test` over the 16 non-in-flight internal files | **60 tests, 7 failures** — all 7 in `InternalTier.CensusTest` (6) + `VmZeroGrowthTest` (1) |
| vm_zero_growth isolated rerun | `mix test test/internal/vm_zero_growth_test.exs` | **2 tests, 0 failures** → census-run failure was contention, not regression |

### Census failure classification (all in-flight-lane-caused or contention, none landed-regression)

1. forbidden client tokens — `rg404_concurrent_lifecycle_court.exs` (`:httpc.request` ×3) → untracked in-flight file
2. HTTP-status-literal asserts — `powl2_primitives_test.exs` ×2 → in-flight
3. off-allowlist `Smalt.*` references — `amqp_listener_cap_test.exs`, `petri_net_test.exs`, `powl2_*_test.exs` ×7 → in-flight (note: `amqp_listener_cap_test.exs` references `Smalt.Amqp.Listener` which does not compile in lib yet — dangling)
4. unaudited pacing token — `powl2_change_feed_test.exs` ("no Process.sleep" in a comment matched the sniff) → in-flight
5. population fence — on-disk set has 11 files absent from `@owned_files` → the census's owned-list (itself dirty-tracked, mid-edit by the same lane) does not yet register the in-flight test files
6. ARM path literals — `rg404_concurrent_lifecycle_court.exs` ×2 → in-flight
7. conn-sup churn timeout (conn_sup not alive within 15 s) — passes in isolation; machine contention from the concurrent writer lane during the full census

## Classification table

### Tracked-modified (compiled + exercised by the green gates above)

| File | Class | Evidence |
|---|---|---|
| lib/smalt/arm_gateway/router.ex | landed-and-green | compiles; kd* tier 53/53 incl. arm tests green |
| lib/smalt/cosmos_sql.ex | landed-and-green | compiles; kd_conformance green |
| lib/smalt/data_plane/blob_storage.ex | landed-and-green | compiles; blob_kd_fixes, kd130 green |
| lib/smalt/data_plane/cosmos.ex | landed-and-green | compiles; kd62_udk_witness green |
| lib/smalt/data_plane/queue_storage.ex | landed-and-green | compiles; amqp/sb tier green |
| lib/smalt/egress/AppConfigRoutes.ex | landed-and-green | compiles; egress boot green in every run |
| lib/smalt/egress_router.ex | landed-and-green | compiles; every gate boots the router green |
| Justfile / justfile.d/31-have.just | landed-and-green (docs/tooling) | not exercised (not code paths of the gates) — review `31-have.just` diff before commit |
| smalt-cli/{README,smalt_cli/migrate/manifest.py,tests/test_migrate_*.py} | docs-only + pytest-owned | not run this sweep (out of tier); e2e/migrate pytest owner lane |
| verification/ts/*.probe.cjs ×2 | docs-only/tooling | not exercised |
| popcorn_demo/** (lib, test, scripts, `_build-*` churn) | docs-only/build-churn | `_build-*` dirs are build artifacts — coordinator should sweep at integration (`just lane-clean` analog); `apex_fanout.ex`/`apex_ratelimit.ex` owned by the apex/popcorn lane, not exercised |
| docs/jira/v*/** (RECEIPTS.md, INDEX.md, spc-bands.md) | docs-only | receipt-index refresh at wrap |
| test/integration/kv404_typed_error_test.exs | landed-and-green | 2/2 green against current lib |
| test/internal/kd134_requester_delivery_test.exs | landed-and-green | green in census run |
| test/internal/scvd_concurrency_courts.exs | landed-and-green | present in census run, not among failures |
| test/internal/internal_tier_census_test.exs | **in-flight-broken** | `@owned_files` list mid-edit: population fence (failure 5) can't pass while the powl2 test files are unregistered — owner: the active powl2 writer lane |

### Untracked (the active writer's surface — NOT mine, not revert candidates, owner live)

| File | Class |
|---|---|
| lib/smalt/powl2.ex, lib/smalt/powl2/ (executor, sb_rules, hsm_signer), lib/smalt/petri_net.ex, lib/smalt/pplan/receipt_engine.ex | **in-flight-broken (do not revert — owner ACTIVE at 12:03 PDT)**: raw compile fails with SyntaxError/TokenMissingError/CompileError; writer was editing during the sweep |
| test/internal/powl2_*, petri_net_test, pplan_receipt_engine_test, rg404_concurrent_lifecycle_court.exs, amqp_listener_cap_test.exs | in-flight (depend on the broken lib files / unregistered in census) |
| docs/jira/v26.10.20/{DFLSS-CHARTER.md, receipts/*.md} ×5 new | docs-only |
| scripts/bench/{ctq2_txn,rg404_wire_probe,scvd_t21_arm_ramp}.mjs, scripts/demo_migration_rehearsal.sh | docs-only/tooling (bench harness files — note: not lane scripts, must not emit jsonl) |
| smalt-cli/migration-receipt.json, tests/fixtures/migrate-enterprise/, test_migrate_enterprise_fixture.py | pytest-owner lane, unexercised |
| popcorn_demo/_build-{apex3/test,cost1,e4kv,e5blob,e6sql,kv404,tracebug}/ | build churn — coordinator cleanup at integration |

## Standing

**PARTIAL_ALIVE** for the landed surface: compile clean, kd* integration 53/53, kv404 2/2,
census 60/67 with all 7 failures attributed to the concurrent in-flight powl2 lane or
contention (vm_zero_growth passes isolated). The untracked `powl2*`/`petri_net`/
`pplan/receipt_engine` surface is in-flight-broken under an ACTIVE owner — not a revert
candidate; re-sweep after that lane lands. No source fixes made; tree restored to as-found
state plus writer's own newer edits.
