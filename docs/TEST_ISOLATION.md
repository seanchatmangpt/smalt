# TEST_ISOLATION

> **RETIRED DOCUMENT (v26.10.19 clean-room reset, commit 64f6099).**
> The legacy `test/` corpus (303 files) this ledger audits was deleted at
> 64f6099. Every file inventory, tag row, and line citation below refers to
> the deleted corpus — history preserved verbatim; the referents live in git
> history only. The isolation law is re-authored and enforced on the
> post-reset tree by:
> - `test/internal/internal_tier_census_test.exs` (residual-tier fence:
>   forbidden tokens + observables allowlist),
> - `scripts/non_duplication_gate.py` (`just non-duplication-gate`;
>   R1/R2/R3 over `test/internal/`),
> - the isolation formatter / court scripts in `scripts/`
>   (`scripts/isolation_court.py`, `gates/test_isolation_leak_gate.py`,
>   `just leak-court` / `just isolation-court`).
> Normative statement: `docs/reference/test-isolation-law.md`.
> The `test/support/` harness (`SmaltTest.*` helpers, isolation formatter,
> runtime exemption registry) went with the corpus — runtime-twin entries
> below have no current referent.
>
> (Earlier note, still true:) the normative contract lives at
> `docs/reference/test-isolation-law.md`; this file remains the historical
> audit ledger.

## Smalt Test Isolation Contract

## 1. Per-test unique keys

Any test that writes into shared state (the coordinator `Store`, an ETS
table, a router surface) MUST derive its keys from `make_ref()` so two
concurrent modules can never collide. Canonical helper:

```elixir
defp unique, do: inspect(make_ref()) |> String.replace(~r/[^0-9a-zA-Z]/, "")
```

Reference implementation: `test/lro_test.exs:547` (`unique/0`).

## 2. Ephemeral / shifted ports

**Config-level ephemeral ports (2026-10-14).** Under `MIX_ENV=test`,
`config/test.exs` evaluates a free-port probe (`:gen_tcp.listen(0)` then
close — the probe-then-close bind race is accepted) for every listener:
`arm_port`, `arm_tls_port`, `egress_port`, `amqp_port`, `event_hubs_port`.
`mix test` therefore ALWAYS boots `Smalt.Application` on free ports, even
while a concurrent keeper/substrate holds the defaults (9443/9444/8443/5672/
5673). Env overrides win over the probe (`SMALT_TEST_ARM_PORT`,
`SMALT_TEST_ARM_TLS_PORT`, `SMALT_TEST_EGRESS_PORT`, `SMALT_TEST_AMQP_PORT`,
`SMALT_TEST_EVENT_HUBS_PORT`); runtime `Application.put_env` still wins over
config (the chaos and wire tiers rely on that). Tests that bind listeners
MUST NOT hardcode the substrate defaults. Use the Application-env contract
(`Application.get_env(:smalt, :arm_port, 9443)`), the shifted-port pattern in
`test/data_plane/blob_service_test.exs`, or `SmaltTest.Lifecycle.shifted_envs/0`.

## 3. Tag vocabulary

Default excludes are configured in `test/test_helper.exs`
(`ExUnit.configure(exclude: [...])`). Every exclusion is a NAMED,
owned exception — not a blanket skip. Re-enable a tier with
`mix test --include <tag>`.

| Tag | Meaning | Owner lane | Re-enable condition |
|---|---|---|---|
| `:amqp_wire` | Drives the real AMQP wire tier (real broker/listener on the AMQP port). Off by default so the plain `mix test` stays broker-independent. Carried by `test/compliance/c5_servicebus.exs` and the `test/amqp/` suites (`broker_facade`, `event_hubs` (2 tests), `management_rpc`, `primitive_codec`, `selector_epoch`). Run via `mix test.amqp_wire`. | amqp wire tier | Broker available; run `mix test --include amqp_wire` |
| `:cross_seat` | Auth cross-seat suite inside `test/auth_enforce_test.exs` (out-of-seat token/seat-boundary cases). **CORRECTED 2026-10-17: `:cross_seat` was NEVER default-excluded** — `test/test_helper.exs` excludes only `:amqp_wire`, so the 8 cross_seat tests run in every plain `mix test`. `mix test.cross_seat` is a selection-only focused run (test + `--only cross_seat` excludes everything untagged), not an isolation mechanism. | R164 | Included-only run: `mix test --only cross_seat test/auth_enforce_test.exs` |
| `:stress` | Stress tier (v26.10.18): 15 expensive test bodies — the byte-identical replay/identity + regen-interleave fences (7 moduletag files, 34+ cases), DETS churn, 1000-PUT shacl fuzz, 10k-op pplan fuzz, 10k cosmos creates, store-restart replay-or-drop. Inventory + measured evidence: `docs/jira/v26.10.18/rewrite-drafts/stress-tier.md` §3. Excluded from plain `mix test` (T1) so load-class 60 s timeout faces stop tripping under suite contention; runs sequentially via `just test-stress`. Tier population fenced by `test/stress_tier_census_test.exs` (>= 20 stress cases assert). | B7 (v26.10.18 harness/tiers lane) | `mix test --include stress` / `just test-stress` |
| `:sovereign_gap` | CLOSED (v26.10.19): retired — the one real product gap (5.3 ARG KQL, ResourceGraph HTTP route family) landed: `POST /providers/Microsoft.ResourceGraph/resources` in EgressRouter backed by `DataPlane.ResourceGraph.query/3` (KQL subset via `DataPlane.KQL`; unimplemented operators typed 400 BadQuery). 5.3 runs untagged in plain `mix test`. Triage: receipts/i29-sovereign-gap-triage.md; closure: receipts/i29-arg-route-family.md | i29 lane | plain `mix test` |
| `:compliance` | Whole-court selection tag on `test/compliance/c1_arm.exs` (the ONLY family carrying it). The 7-family compliance corpus (170 tests) is loaded and fenced by `test/compliance_test.exs` / `just test-compliance` — added 2026-10-17; before that the `test/compliance/*.exs` filenames never matched the `*_test.exs` glob and the 170 tests never ran in any gate. | compliance tier | `mix test test/compliance_test.exs` (154 run / 16 c5 skip by default); `just test-compliance-wire` for the full 170 |
| ~~`:arm_seam`~~ | **RETIRED 2026-10-15 (V261014-13)**: vacuous exclusion entry deleted from `test/test_helper.exs`; no test carries this tag; re-introduce only with a real named-gap test. `GAP(vacuous-tag-arm-seam)` CLOSED — token deleted | — | — |
| ~~`:dp_seam`~~ | **RETIRED 2026-10-15 (V261014-13)**: the re-enable condition landed (`Store.list_prefix/2` at `lib/smalt/store.ex:128`, used by `lib/smalt/data_plane/cosmos.ex:504,589`), no test carries the tag, and the cosmos fallback this row described is gone (If-Match replace is now one atomic `Store.compare_and_swap/4`); vacuous exclusion entry deleted from `test/test_helper.exs`; re-introduce only with a real named-gap test. `GAP(vacuous-tag-dp-seam)` CLOSED — token deleted | — | — |
| ~~`:closed_shape_gap`~~ | **RETIRED 2026-10-15**: the vacuous exclusion entry was deleted from `test/test_helper.exs` (store+graphlaw lane, cycle-6 receipt). No test carries this tag; re-introduce it only with a real named-gap test. | — | — |

## 4. Audit findings (re-audited 2026-10-15; 2026-10-14 snapshot superseded)

- `async: true` — 16 files (re-derived at HEAD 2026-10-18 by
  `grep -rln "async: true" test/ --include='*.exs'`):
  `test/amqp/delivery_encoder_test.exs`, `test/amqp/fuzz_test.exs`,
  `test/amqp/primitive_codec_test.exs`, `test/assert_eventually_test.exs`,
  `test/data_plane/kql_test.exs`, `test/defaults_test.exs`,
  `test/dspy_test.exs`, `test/enclave_hcl_test.exs`,
  `test/fin_ops_calculator_test.exs`, `test/ocel_conformance_test.exs`,
  `test/ocel_revops_test.exs`, `test/provider_matrix_test.exs`,
  `test/shacl_projection_test.exs`, `test/smalt_graphlaw_matrix_test.exs`,
  `test/smalt_graphlaw_validator_test.exs`, `test/stress_tier_census_test.exs`.
  The six new files since the 2026-10-15 snapshot (11 files) are
  `assert_eventually`, `defaults`, `enclave_hcl`, `fin_ops_calculator`,
  `provider_matrix`, `stress_tier_census`. `test/amqp/management_rpc_test.exs`
  LEFT the inventory: it is now `async: false` ×2 (`use ExUnit.Case` at :8
  and the :585 module) because its setup wipes the SHARED sb tables —
  under `async: true` that raced sibling tests' enqueues (witnessed DLQ
  corruption under shuffle; citation
  `docs/jira/v26.10.17/receipts/i21d-store-clear-async.md`).
  ALL 16 are `Store`-clean (re-verified per-file
  `grep -c "Store\\." -> 0` at HEAD; the single `smalt_graphlaw_matrix`
  hit is its in-file comment documenting the earlier fix). The 2026-10-14
  offender (graphlaw matrix starting its own Store under `async: true`)
  stays RESOLVED. No async+Store race remains.
- `Store.clear` — 39 files / 53 call sites under `test/` (re-derived at
  HEAD 2026-10-18 by `grep -rn "Store\.clear" test/`), plus 2 lib sites in
  `lib/smalt/enclave/doctor.ex` (:277, :292 — the enclave doctor's own
  reset path, not test code). The 53 test sites decompose as 37 `.exs`
  test modules + 2 `test/support` helpers (`store_resilient.ex`,
  `wire_helpers.ex`). All clearing test modules are `async: false` — with
  the `management_rpc` flip above, no `async: true` module touches the
  shared Store. Inventory (37 modules):
  `test/apiversion_matrix_test.exs`, `test/arm_cascade_teardown_test.exs`,
  `test/arm_error_corpus_test.exs`, `test/arm_secret_rotate_test.exs`,
  `test/azsim/control_plane_test.exs`, `test/azsim/dets_recovery_test.exs`,
  `test/corpus/helper.exs`, `test/corpus/shacl_fuzz.exs`,
  `test/data_plane/audit_planes_test.exs`,
  `test/data_plane/blob_hardening_test.exs`,
  `test/data_plane/blob_service_test.exs`,
  `test/data_plane/conditional_headers_test.exs`,
  `test/data_plane/cosmos_sql_test.exs`, `test/data_plane/cosmos_test.exs`,
  `test/egress_dispatch_test.exs`, `test/egress_kv_appconfig_test.exs`,
  `test/egress_secrets_test.exs`, `test/egress_wiring_test.exs`,
  `test/enclave_engine_test.exs`, `test/enclave_lifecycle_test.exs`,
  `test/enclave_ocel_test.exs`, `test/enclave_state_test.exs`,
  `test/kd79_blob_apiversion_wire_test.exs`,
  `test/kv_secrets_children_test.exs`, `test/lro_test.exs`,
  `test/policy_rbac_test.exs`, `test/pplan_test.exs`,
  `test/route_negative_test.exs`, `test/runtime_contracts_test.exs`,
  `test/sb_children_test.exs`,
  `test/security/security_hardening_test.exs`,
  `test/smalt_arm_gateway_test.exs`,
  `test/smalt_egress_router_test.exs`,
  `test/smalt_ets_baseline_identity_test.exs`,
  `test/smalt_ets_composite_identity_test.exs`,
  `test/smalt_native_hcl_ladder_test.exs`,
  `test/zero_drift_serialization_test.exs`.
- Fixed substrate ports — the wire tier (`test/wire/*_test.exs`) pins the
  default ports by design (that is the tier's contract). Outside the wire
  tier, listeners are ephemeral-port or Application-env driven (re-verified
  2026-10-15): the compliance courts (c1..c7) probe free ports with
  `:gen_tcp.listen(0)`; `test/chaos/*` reads/sets the Application-env
  contract (lawful); `test/data_plane/blob_service_test.exs` uses the shifted
  ports above; the amqp tier, `test/tls_test.exs`, `test/kv_tls_test.exs`,
  `test/metadata_endpoints_test.exs`, `test/eventgrid_conformance_test.exs`,
  `test/canonical_projection_test.exs`, and `test/mcp_wire_test.exs` boot
  their own listeners on ephemeral ports; `test/data_plane/key_vault_actions_test.exs`
  uses `smalt.local:8443` only as string KIDs (no bind).
- `test/sdk-smoke/*` hardcodes substrate ports but is a separate Node-driven
  smoke tier that owns its substrate lifecycle (see `test/sdk-smoke/eh-run.mjs`
  env-var overrides) — out of scope for `mix test` isolation.
- **Kill-restart contract** (added 2026-10-15, work order V261014-02 / lens7
  canonical): any test that takes a supervised child down
  (`Supervisor.terminate_child`, `restart_child`, or a supervised-child
  `Process.exit(pid, :kill)`) MUST restore it **synchronously in the test
  process** — `try/after` wrapping the kill window + a checked restart
  (`{:error, {:already_started, _}}` / `{:error, :already_present}` count as
  success, anything else `flunk`s) + a liveness wait + a state verification
  sweep (all named ETS tables `:ets.info/1 != :undefined`, via
  `Smalt.Store.table_names/0`) — before the test reports. An `on_exit`-only
  restore is a defect: `on_exit` runs in a separate ExUnit process after the
  test reports, so a test process that dies mid-window (flunk/timeout) leaks
  the dead child process-wide and every subsequent test fails with a
  shuffle-order-dependent first victim. Reference implementation:
  `test/pplan_test.exs` `restore_store!/0` delegating to
  `SmaltTest.Lifecycle.ensure_store_up/0` (test_helper.exs).
- **Killer inventory** (re-audited 2026-10-15;
  `grep -rn "terminate_child|restart_child|Process.exit(.*:kill)" test/`):
  supervised-child kills are confined to `test/pplan_test.exs` — lens7
  `terminate_child` :2732 / `restart_child` :2725 (on_exit net) / :2768
  (in-window, now inside `try/after`), and lens6 `Process.exit(pid, :kill)`
  :2545 (safe: `:permanent` child restarts via the supervisor). All other
  `Process.exit(..., :kill)` hits kill test-owned processes (claimants,
  racers, private supervisors/servers the test itself started) — not shared
  supervised children; `test_helper.exs` kill-fallbacks in
  `Lifecycle.stop_shared_tree/0` are the sanctioned shared-tree stop path.

## 5. v26.10.16 — ETS-contamination class (store_read fences + shared-table hygiene)

Landed 2026-10-16; receipts
`docs/jira/v26.10.16/receipts/r178g-ets-hygiene-batch.md` and
`docs/jira/v26.10.16/receipts/r185i-r185k-harness-batch.md`.

### 5a. Read-path fence: refuse non-map Store rows (`Smalt.Semantic.StoreRead`)

`lib/smalt/semantic/store_read.ex` is the read path from the semantic surface
into the shared, untyped ETS `Store`. Because every suite shares those
tables, one suite's stray row used to crash (or poison) another suite's read.
Fences now guard every projected table:

- `refuse_non_map_rows/2` (`store_read.ex:26`, `:34`, `:41`; def `:73-74`):
  a non-map value under `:smalt_resources`, `:smalt_ledger_transactions`, or
  `:ocel_deviations` refuses the whole read TYPED (`{:error, msg}`) — never a
  `FunctionClauseError` from `project_resource/1`, never a silent skip. This
  is the boundary-crash class lens-1 closed at the ledger boundaries.
- `refuse_vacuous_identity/3` (`:89`): a row whose identity key is nil/`""`
  (or whitespace-only, via `Smalt.Projection.Identity.valid?/1`) refuses the
  read typed too — a PK-less struct carries zero identity bits.
- Field-VALUE policy stays lenient by design (`:124`, `:132`): a
  non-conformant value projects nil (parse_ts precedent); only row STRUCTURE
  and identity are refused.

Test-visible consequence: a poisoned shared table now fails as a typed
`{:error, "semantic projection: non-map Store row ..."}` naming the table,
so the contaminating suite is identifiable from the failure alone.

### 5b. Shared-table cleanup pattern (success-path delete + on_exit)

Every test seeding rows into a SHARED ETS table (`:smalt_resources` et al.)
must clean up on BOTH paths, deleting only its own prefix:

1. Success-path delete inside the test body (covers the normal case).
2. `on_exit` guard (covers flunk/timeout exits), gated on the table being
   alive:

```elixir
on_exit(fn ->
  if :ets.info(@table) != :undefined do
    for key <- Smalt.Store.prefix_keys(@table, @prefix), do: :ets.delete(@table, key)
  end
end)
```

Model implementation: `test/store_churn_test.exs:17`. The prefix-scoped
delete (not `delete_all_objects`) is the point: the table is shared, so a
nuclear wipe would destroy other suites' state mid-run.

Two sanctioned variants exist:
- Whole-table wipe (`:ets.delete_all_objects(:smalt_resources)`) is allowed
  ONLY where the suite is the table's sole realistic tenant within the run —
  the R185i `audit_planes` quarantine (`test/data_plane/audit_planes_test.exs:25`)
  seeds id-less maps (`%{"name" => "r1"}`) that poison later semantic-read
  tests with "vacuous identity" refusals, and clearing only at setup let rows
  outlive the test until the NEXT audit_planes setup under ExUnit shuffle.
- Record-and-delete guards on specific seeded keys (R178g batch:
  `test/strata_compat_test.exs:272/:278`, `test/mcp_test.exs:40/:46/:903`,
  `test/mcp_wire_test.exs:18`, `test/smalt_arm_gateway_test.exs:701` — the
  rg-a/rg-b/rg-p seed batch, 104 keys).

Non-vacuity: `scripts/shim_court/strata_cleanup_court.sh` shims the cleanup
out and proves the non-map-row leak reproduces on the real shared ETS
(`[PASS] strata_cleanup_court`, restore byte-exact; witness in the r178g
receipt).

### 5c. Session cleanups landing under this class

- **R178g** (strata CAS row): the compare-and-swap test now deletes its
  seeded row on the success path (`test/store_churn_test.exs` CAS tests) in
  addition to the setup `on_exit`; non-map row leak court-verified non-vacuous.
- **R185i** (frame-property winner row + audit_planes quarantine):
  `test/property/frame_codec_property_test.exs` (7 properties, 0 failures)
  runs the AMQP frame codec property suite — the surviving winner row of its
  batch — and the audit_planes `on_exit` quarantine described in 5b.
  `test_helper.exs` `wait_gone/2` is all-`defp` (the mixed def/defp compile
  error was fixed by the SHIM-COURT-lane-R185i unblock, disclosed in-source
  at line 81).
- **R189** (arm/mcp seed cleanups): `on_exit` cleanup blocks landed in
  `test/mcp_test.exs`, `test/mcp_wire_test.exs`, and
  `test/smalt_arm_gateway_test.exs` so seeded `:smalt_resources` rows never
  leak across tests.

Verification (from the receipts, 2026-10-16): 102 tests 0 failures across
store_churn + strata + mcp + arm_gateway; management_rpc 33/0; strata
cleanup court PASS with byte-exact restore.

## 6. Isolation court (AZB-11) — static + runtime twin

Landed v26.10.17/18 (`scripts/isolation_court.py`,
`justfile.d/25-leak-court.just`). Two twins over one surface:

**Static twin** (`just isolation-court`, default mode): extends
`gates/test_isolation_leak_gate.py`'s env scanner (inherited, not
duplicated) with three rules over every `test/**/*.exs` (minus
`test_helper.exs` and the twin probe file):

1. **Env-restore rule** — every `Application.put_env/delete_env/...`
   mutation must be covered by a save-prev + `on_exit` restore. The house
   helper `SmaltTest.Env.put_restored(k: v, ...)` counts as fully covered
   (structural save-prev + on_exit). Inline exemption only via a mandatory
   `# isolation-court: exempt <reason>` marker on the offending line.
2. **start_link discipline** — a bare `GenServer/Agent/Task.start_link`
   (or any `start_link` with a literal `name:`) in a test body must be
   `start_supervised!/1` (or `SmaltTest.Singleton.start_supervised_singleton!`,
   or an error-path assert). Same inline-exemption channel.
3. **Fail-closed fixtures** — the court runs its own in-memory
   positive/negative fixtures on every invocation (a bare `put_env` must be
   REFUSED naming file:line; the `put_restored` discipline must PASS), so
   a scanner regression cannot read as a green run. `--self-check` proves
   the same on real temp files, including the exemption-marker path.

**Runtime twin** (`just isolation-court-runtime`, `--runtime-only`): boots
the offline suite serially (`mix test --formatter
SmaltTest.IsolationFormatter --max-cases 1`) and diffs
`Process.registered()` + `Application.get_all_env(:smalt)` per module; any
`ISOLATION-TWIN LEAK module=...` block fails the court. Baseline witness:
`tmp/isolation-court-runtime.out` (26/153 modules leaked pre-exemption).

**Exemption registry** (`test/support/isolation_runtime_exemptions.exs`):
typed, per-pattern runtime exemptions — one `name <glob> # reason: <text>`
line per entry, mandatory reason, currently 14 patterns in three classes:
lib-owned lazy singletons (`LedgerWriter`, `WasmEngine*`, `EventGrid`),
harness-owned shared-tree members (`Smalt.Supervisor`, `Store`,
`AmqpBroker*`, `Amqp.*`, `LRO.*`, `Plane.*`, …), and kernel/VM-lifetime
processes (`:inet_gethost_native*`, `:dets`, `:dets_sup`, `PPlan.Task`).
Exemption applies ONLY to registered-name deltas — a leak block carrying
any env delta is never exemptable (fail-closed). A malformed registry line
REFUSES the court.

## 7. SleepWindows — named B1 time-advance windows

`test/support/sleep_windows.ex` (`SmaltTest.SleepWindows`) is the Law-1 B1
annotated exception to the no-sleep doctrine (`docs/NO_SLEEP_DOCTRINE.md`):
where the condition under test IS time (rate-limit window alignment,
LRO delay/retention elapse, tombstone grace, wire keep-alive idle gap), no
observable can be polled, so the sleep is named and derived from its
configured constant instead of a bare literal. Six windows:
`second_boundary_ms/1`, `fixed_window_rollover_ms/1`, `lro_delay_elapse_ms/2`,
`lro_deadline_elapse_ms/1`, `sweeper_grace_elapse_ms/2`, `mcp_idle_gap_ms/1`.
The adjacent sleep keeps its `# SLEEP-CLASS: TIME-ADVANCE` annotation.
Current consumers (grep `SmaltTest.SleepWindows\.` test/, 2026-10-18):
`test/amqp/sweeper_test.exs`, `test/arm_error_corpus_test.exs`,
`test/compliance/c1_arm.exs`, `test/mcp_wire_test.exs`,
`test/smalt_arm_gateway_test.exs`.