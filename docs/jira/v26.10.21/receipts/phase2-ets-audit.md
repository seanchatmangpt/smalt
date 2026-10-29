# T38P2 Receipt — ARD Phase-2 ETS Claims vs. Actual Substrate (Census)

Context: solo

**Standing:** **PARTIAL / MOSTLY REFUTED as-stated.** Zero Phase-2 OTP-29 idioms exist in `lib/smalt` today.
None of the four Phase-2 pillars has landed; each must be treated as new work, not a confirmation pass.
Date: 2026-10-21. Repo: /Users/sac/smalt. Scope: `lib/smalt/**` only, `grep :ets.new` census (55 call sites, 40+ files).

## 1. Claim-by-claim typed table

| # | ARD claim (ARD-PRD.md §Phase 2, lines 94/104/113/121/408) | Current state (substrate) | Gap | Risk |
|---|---|---|---|---|
| C1 | All shared ETS tables: `{write_concurrency, auto}` + `{read_concurrency, true}` (+ implied `decentralized_counters`) | **`:auto` appears NOWHERE.** 0 of ~55 `:ets.new` sites use `write_concurrency: :auto`. 16 sites use boolean `write_concurrency: true`; ~39 use default (false) | Re-flag all ~55 sites; verify `:auto` + `decentralized_counters` are actually valid on the target OTP before mass edit | Low per-site (mechanical), Medium aggregate (contention profile changes; perf gate at ARD line 96 untested) |
| C2 | Traversal/rate-limit loops use `ets:next_lookup/1` (+ `ets:update_element/4`) — single atomic cycle | **0 uses of `next_lookup`/`prev_lookup` in lib/smalt.** Traversal is lookup+next pairs: `store.ex:161-175` (`ordered_walk/3` over `:ets.next/2`, backing `keys/1`/`prefix_keys/2` — used by arm_gateway/router.ex:888,6343, metrics.ex:86); `cosmos.ex:529` (`:ets.next/2`); `amqp/queue_store.ex:757-765` deliberately avoids prefix walk, uses `:ets.match_object/2` | Rewrite ordered_walk to next_lookup; queue_store's match_object path may already meet the "single atomic cycle" intent — type before migrating | Low-Medium: next_lookup on `:"$end_of_table"` semantics + guard against concurrent deletes during walk (ST4-class read race the queue_store comment already documents) |
| C3 | Singleton GenServer coordination → `Registry.lock/3` on composite keys | **Elixir `Registry` module is not used anywhere in lib/smalt** (all "Registry" greps hit the domain module `Smalt.Registry`, a ggen-projected resource catalog). Coordination is ~30 singleton named GenServers; the hot path is `Smalt.Store` (`store.ex`): `cas/4`, `insert_new/3`, `cas_delete/3`, `next_seq/3` are `handle_call`s doing lookup-then-write inside the single Store process | Store CAS is **NOT atomics-based** (census verified — the ARD "already atomics-based" assumption is wrong). It is GenServer-serialized BY DESIGN: `next_seq` doc (store.ex:277-301) records that caller-side ETS CAS raced (lookup+insert window clobbered bumps) and serialization is the structural fix | HIGH: naive Registry.lock/3 swap re-introduces the exact race next_seq's comment documents. Only ETS-native atomics (`insert_new`, `update_counter` w/ thresholds) preserve atomicity without the funnel; `cas` lookup-then-insert cannot be made atomic via plain ETS on set tables without :ets atoms (needs ordered tricks or keep funnel). Also: no PartitionSupervisor, no Registry process; ~30 GenServers, 1 DynamicSupervisor (amqp/listener.ex:160) |
| C4 | Ingestion worker pools governed by PartitionSupervisor + `resize!/2` | **`PartitionSupervisor` appears 0 times in lib/, test/** | Whole pillar unimplemented; also listed as OTP-29 probe-pending in ARD line 31 | Medium: blocked on otp29-capability-probes receipt; nothing to migrate, greenfield |
| C5 | (implicit) heir-style ownership ("shadow-table law") | ~29 files use `{:heir, Process.whereis(:init), []}` 3-tuple form consistently (commented as the 3-tuple-only form; keyword form raises) | None — this is the one substrate pattern fully consistent with the ARD's survivability story | Low |

## 2. Table-by-table `:ets.new` census (lib/smalt)

Legend: WC=write_concurrency, RC=read_concurrency. Default WC is false everywhere except listed.

**A. `write_concurrency: true` (boolean, 16 sites) — closest to C1, still not `:auto`:**
- lib/smalt/telemetry.ex:267 (`:smalt_rolling_counters`)
- lib/smalt/store.ex:37-43 (Store tables, WC+RC true)
- lib/smalt/egress_router.ex:3917 (`:smalt_egress_counters`)
- lib/counters-style counter tables: blob_storage.ex:398 & 2684, kv_managed_storage_ex 66, data_plane/sentinel.ex:102 (ordered_set), certificates.ex:85, file_share.data... file_share.ex:48, appconfig_revisions.ex:37, cosmos_authz.ex:56, arm/resource_health.ex:142, pplan/task.ex:435, messaging/eh_geo_dr.ex:146, messaging/event_hubs.ex:703, messaging/amqp/sweeper.ex:162, projection/admission.ex:309-313 (admission tables take optional `heir: owner` variant)

**B. `{:heir, Process.whereis(:init), []}` (heir-to-init, no WC) — 20+ sites, "shadow-table law":**
metric_alerts.ex:256, app_insights:106, activity_log:240, monitor/metrics.ex:303, arm_gateway/router.ex:214 (:smalt_arm_rate, RC+heir), blob_cors:20, cosmos_consistency:127, blob_soft_delete:29/39/300, table_storage:265/279, blob_storage:816(snapshot)/2732(sw_props), cosmos.ex:2306 (:smalt_cosmos_ru), arm/dns:25, arm/rbac:29ff, arm/deployments.ex:35, arm/resource_providers.ex:144, eh_capture:153, eh_throttle:46, eh_schema_registry:31, amqp/rule_store:379/409, key_vault_actions:606, appconfig_snapshots:50, cosmos_consistency:127

**C. Bare / RC-only, no WC, no heir (7+ sites):**
- powl2/change_feed.ex:86-87 (docs + cdc, RC only)
- powl2/s groups: powl2/sb_rules.ex:129-130 (@table + @dlq, RC only)
- amqp/connection.ex:1345 (`:smalt_eh_epochs`, RC only)
- amqp/cbs_router.ex:92 (`:smalt_cbs_claims`, **:private**, keypos 1) — sole private table
- arm_gateway/router.ex:3188 (affidavit witness, RC only)

## Bucket C/B vs A is the C1 gap in one line: 0 :auto, 16 boolean-true, ~39 default-false.

## 3. Verified non-claims (negative results, grep-exhaustive over lib/ + test/)
- `write_concurrency: :auto` — 0 hits
- `next_lookup` / `prev_lookup` — 0 hits
- `update_element` — 0 hits in traversal paths (some :ets.update_counter use exists: store.ex:250 update_counter IS ETS-atomic; current_counter lookup fallback)
- `PartitionSupervisor` — 0 hits in lib/ and test/
- Elixir `Registry.lock/3` / `Registry` supervisor module — 0 hits (only domain `Smalt.Registry` domain catalog module)
- Store CAS path atomics-based — **FALSE**; cas/insert_new/cas_delete/next_seq are handle_call-serialized through the Store singleton (store.ex:270-375). Only `update_counter/4` (store.ex:250) is a true ETS atomic. The serialization is deliberate (see next_seq doc, store.ex:277-301: prior caller-side CAS raced and clobbered bumps).

## 4. Standing & next actions
- C1: mechanical re-flag of ~55 sites AFTER otp29 probe validates :auto + decentralized_counters on target OTP.
- C2: migrate `ordered_walk/3` (store.ex:161-175) and cosmos.ex:529 to next_lookup; queue_store match_object path: type as already-satisfying or migrate.
- C3: DO NOT naively swap Store funnel for Registry.lock/3 — next_seq race history says serialization is load-bearing. Split: atomics-capable ops (insert_new, update_counter) can leave the funnel; true CAS needs a redesign, not a decoupling.
- C4: greenfield, blocked on OTP-29 capability probe (ARD line 31).
- Receipt: docs/jira/v26.10.21/receipts/phase2-ets-audit.md (this file). Standing: PARTIAL — the ARD Phase-2 items are forward work items, not landed capability claims.