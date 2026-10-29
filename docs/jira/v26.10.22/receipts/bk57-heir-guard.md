# BK-57: heir-guard mechanical gate

**Standing:** **ALIVE** (gate run for real on tree: 37/37 guarded, exit 0; self-test + real-tree mutation probe both witnessed)

Context: solo

Closes the BK-33 typed residual: every `{:heir, Process.whereis(:init), []}`
ETS table must carry an existence guard (`:ets.info` / `:ets.whereis` with
delete-stale or `rescue ArgumentError`) before `:ets.new` on its init path, or
a warm `System.restart/0` halts the VM on "table name already exists"
(metrics.ex was the one unguarded site that caused the halt).

## Gate

`scripts/heir_guard_check.py` (fail-closed, sleep-gate/invariant-gate style):

1. Scans `lib/**/*.ex` for `:ets.new` calls whose option list contains
   `:heir` (balanced-paren call extraction — multiline option lists covered).
2. Per site, classifies the guard using the same-file heuristic:
   - **GUARDED** — a `:ets.info(T)` / `:ets.whereis(T)` expression exists
     whose argument matches the site's table token (`@table`, local var, or
     the resolved `@table :name` atom). `:ets.whereis` is accepted because
     apim/metric_alerts/atom_bridge execute the same delete-stale-or-rescue
     law via the `whereis` + `rescue ArgumentError` idiom.
   - **UNGUARDED** — zero `:ets.info`/`:ets.whereis` occurrences in the file
     (guard provably absent).
   - **UNPROVABLE** — guards exist in the file but none matches this table
     (heuristic cannot prove presence or absence).
   UNGUARDED and UNPROVABLE both exit 1 — no silent passes.
3. `--self-test` plants a temp module with an heir `:ets.new` and no guard;
   the gate must classify it as failing, else **exit 2 VACUOUS GATE**.

Wired: `just heir-guard` / `just heir-guard-self-test`
(`justfile.d/49-heir-guard.just`, root Justfile import appended).

## Census — 2026-10-21, current tree (main @ 2bcfe38 + dirty working set)

37 heir `:ets.new` sites, **37 GUARDED, 0 failing** — exit 0.

| Site | Guard |
|---|---|
| lib/smalt/apim.ex:151 | `:ets.whereis(@rate_table)` (:smalt_apim_rate_limit) |
| lib/smalt/policy.ex:68 | `:ets.info(table)` |
| lib/smalt/store.ex:97 | `:ets.info(table)` |
| lib/smalt/telemetry.ex:289 | `:ets.info(:smalt_rolling_counters)` |
| lib/smalt/monitor/activity_log.ex:240 | `:ets.info(@ring)` |
| lib/smalt/monitor/app_insights.ex:106 | `:ets.info(@table)` |
| lib/smalt/monitor/metric_alerts.ex:256 | `:ets.whereis(@table)` |
| lib/smalt/monitor/metrics.ex:313 | `:ets.info(@table)` |
| lib/smalt/arm_gateway/router.ex:227 | `:ets.info(:smalt_arm_rate)` |
| lib/smalt/arm/deployments.ex:35 | `:ets.info(table)` |
| lib/smalt/arm/dns.ex:25 | `:ets.info(table)` |
| lib/smalt/arm/rbac.ex:37 | `:ets.info(table)` |
| lib/smalt/arm/resource_health.ex:142 | `:ets.info(@table)` |
| lib/smalt/arm/resource_providers.ex:144 | `:ets.info(@table)` |
| lib/smalt/data_plane/appconfig_revisions.ex:37 | `:ets.info(@table)` |
| lib/smalt/data_plane/appconfig_snapshots.ex:50 | `:ets.info(@table)` |
| lib/smalt/data_plane/blob_cors.ex:20 | `:ets.info(@table)` |
| lib/smalt/data_plane/blob_soft_delete.ex:29,39,300 | `:ets.info(@deleted_table)` / `:ets.info(@versions_table)` / `:ets.info(@props_table)` |
| lib/smalt/data_plane/blob_storage.ex:2790 | `:ets.info(@sw_props_table)` |
| lib/smalt/data_plane/certificates.ex:85 | `:ets.info(@table)` |
| lib/smalt/data_plane/cosmos.ex:2383 | `:ets.info(:smalt_cosmos_ru)` |
| lib/smalt/data_plane/cosmos_authz.ex:56 | `:ets.info(t)` |
| lib/smalt/data_plane/cosmos_consistency.ex:127 | `:ets.info(@table)` |
| lib/smalt/data_plane/file_share.ex:70 | `:ets.info(@table)` |
| lib/smalt/data_plane/key_vault_actions.ex:606 | `:ets.info(@deleted_table)` |
| lib/smalt/data_plane/kv_managed_storage.ex:66 | `:ets.info(@table)` |
| lib/smalt/data_plane/table_storage.ex:265,279 | `:ets.info(@tables_table)` / `:ets.info(@entities_table)` |
| lib/smalt/messaging/eh_capture.ex:153 | `:ets.info(@table)` |
| lib/smalt/messaging/eh_schema_registry.ex:31 | `:ets.info(@table)` |
| lib/smalt/messaging/eh_throttle.ex:22 | `:ets.info(@table)` |
| lib/smalt/messaging/amqp10/amqp10_ledger.ex:61 | `:ets.info(@table)` (:amqp10_settled) |
| lib/smalt/messaging/amqp/atom_bridge.ex:143 | `:ets.whereis(@rate_limit_table)` |
| lib/smalt/messaging/amqp/rule_store.ex:379,409 | `:ets.info(@table)` (:smalt_sb_rules) |
| lib/smalt/messaging/amqp/sb_auth_rules.ex:236 | `:ets.info(@table)` |

Tree truth notes: BK-45's RollingCounters heir work **has landed** — the
`:smalt_rolling_counters` heir site (telemetry.ex:289) is guarded by the
literal `:ets.info(:smalt_rolling_counters)` check before `:ets.new`. No
UNPROVABLE rows were emitted on the current tree.

## Verification transcript (real runs)

```
$ just heir-guard-self-test
[self-test] bad.ex -> UNGUARDED (no :ets.info/:ets.whereis anywhere in file)
[self-test] good.ex -> GUARDED
self-test PASS: planted unguarded heir site is refused
self-test exit=0

$ just heir-guard            # full 37-row output above, tail:
[ok] lib/smalt/messaging/amqp/sb_auth_rules.ex:236 guard :ets.info(@table)
heir-guard: 37 heir :ets.new sites, 37 guarded, 0 failing
gate exit=0

$ # real-tree mutation probe: temp copy of lib/, metrics.ex :ets.info guard
$ # deleted (asserted absent post-shim), gate re-run over the copy:
shimmed metrics.ex -> [('/tmp/heir-shim.qkD6/lib/smalt/monitor/metrics.ex',
  308, 'UNGUARDED', 'no :ets.info/:ets.whereis anywhere in file')]
# gate flips to a typed failure on the exact BK-33 defect class; copy deleted
```

Exit contract: 0 all-guarded / 1 UNGUARDED-or-UNPROVABLE (typed rows) /
2 self-test vacuous. Not wired into `just court` in this change (left to the
milestone wrap owner, matching 48-private-trip's posture).

Not committed (per dispatch).
