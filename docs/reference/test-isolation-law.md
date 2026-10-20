# test isolation law

> **Post-reset note (64f6099).** The legacy `test/` corpus (303 files) was deleted in
> the clean-room reset. The per-file and `file:line` citations below refer to the
> deleted corpus unless they name `test/internal/` — RETIRED@64f6099, preserved as the
> normative statement; enforcement on the post-reset tree is
> `test/internal/internal_tier_census_test.exs`, `scripts/non_duplication_gate.py`,
> `scripts/isolation_court.py`, `gates/test_isolation_leak_gate.py`
> (`just leak-court` / `just isolation-court`), and the `verification/{ts,py}` suites.

The normative contract every suite in `test/` is held to, plus the courts
and registries that enforce it. Absorbs `docs/TEST_ISOLATION.md` (which
remains as the historical audit ledger); adds the async topology, the
isolation court, and the runtime exemption registry.

## 1. Per-test unique keys

Any test that writes into shared state (the coordinator `Store`, an ETS
table, a router surface) MUST derive its keys from `make_ref()` so two
concurrent modules can never collide. Canonical helper:

```elixir
defp unique, do: inspect(make_ref()) |> String.replace(~r/[^0-9a-zA-Z]/, "")
```

Reference implementation: `test/lro_test.exs:547` (`unique/0`).

## 2. Ephemeral / shifted ports

**Config-level ephemeral ports.** Under `MIX_ENV=test`, `config/test.exs`
evaluates a free-port probe (`:gen_tcp.listen(0)` then close — the
probe-then-close bind race is accepted) for every listener: `arm_port`,
`arm_tls_port`, `egress_port`, `amqp_port`, `event_hubs_port`. `mix test`
therefore ALWAYS boots `Smalt.Application` on free ports, even while a
concurrent keeper/substrate holds the defaults (9443/9444/8443/5672/5673).
Env overrides win over the probe (`SMALT_TEST_ARM_PORT`,
`SMALT_TEST_ARM_TLS_PORT`, `SMALT_TEST_EGRESS_PORT`,
`SMALT_TEST_AMQP_PORT`, `SMALT_TEST_EVENT_HUBS_PORT`); runtime
`Application.put_env` still wins over config (the chaos and wire tiers rely
on that). Tests that bind listeners MUST NOT hardcode the substrate
defaults. Use the Application-env contract
(`Application.get_env(:smalt, :arm_port, 9443)`), the shifted-port pattern
in `test/data_plane/blob_service_test.exs`, or
`SmaltTest.Lifecycle.shifted_envs/0`.

## 3. Tag vocabulary

Default excludes are configured in `test/test_helper.exs`
(`ExUnit.configure(exclude: [...])`). Every exclusion is a NAMED, owned
exception — not a blanket skip. Re-enable a tier with
`mix test --include <tag>`.

| Tag | Meaning | Owner lane | Re-enable condition |
|---|---|---|---|
| `:amqp_wire` | Drives the real AMQP wire tier (real broker/listener on the AMQP port). Off by default so plain `mix test` stays broker-independent. Carried by `test/compliance/c5_servicebus.exs` and the `test/amqp/` suites. Run via `mix test.amqp_wire`. | amqp wire tier | Broker available; `mix test --include amqp_wire` |
| `:cross_seat` | Auth cross-seat suite inside `test/auth_enforce_test.exs` (out-of-seat token/seat-boundary cases). CORRECTED 2026-10-17: `:cross_seat` was NEVER default-excluded — `test/test_helper.exs` excludes only `:amqp_wire`, so the 8 cross_seat tests run in every plain `mix test`. `mix test.cross_seat` is a selection-only focused run, not an isolation mechanism. | R164 | `mix test --only cross_seat test/auth_enforce_test.exs` |
| `:stress` | Stress tier (v26.10.18): 15 expensive test bodies — the byte-identical replay/identity + regen-interleave fences (7 moduletag files, 34+ cases), DETS churn, 1000-PUT shacl fuzz, 10k-op pplan fuzz, 10k cosmos creates, store-restart replay-or-drop. Excluded from plain `mix test` (T1); runs sequentially via `just test-stress`. Population fenced by `test/stress_tier_census_test.exs` (>= 20 stress cases assert). | B7 (v26.10.18 harness/tiers lane) | `mix test --include stress` / `just test-stress` |
| `:compliance` | Whole-court selection tag on `test/compliance/c1_arm.exs` (the ONLY family carrying it). The 7-family compliance corpus (170 tests) is loaded and fenced by `test/compliance_test.exs` / `just test-compliance`. | compliance tier | `mix test test/compliance_test.exs` (154 run / 16 c5 skip by default); `just test-compliance-wire` for the full 170 |
| ~~`:arm_seam`~~ | **RETIRED 2026-10-15**: vacuous exclusion entry deleted from `test/test_helper.exs`; no test carries this tag; re-introduce only with a real named-gap test. | — | — |
| ~~`:dp_seam`~~ | **RETIRED 2026-10-15**: the re-enable condition landed (`Store.list_prefix/2` at `lib/smalt/store.ex:128`, used by `lib/smalt/data_plane/cosmos.ex`), no test carries the tag, vacuous exclusion entry deleted from `test/test_helper.exs`. | — | — |
| ~~`:closed_shape_gap`~~ | **RETIRED 2026-10-15**: vacuous exclusion entry deleted from `test/test_helper.exs`; no test carries this tag. | — | — |

## 4. Async topology

- **`async: true` — 11 files, all Store-clean** (grep-verified 2026-10-15):
  `test/dspy_test.exs`, `test/ocel_revops_test.exs`,
  `test/ocel_conformance_test.exs`, `test/shacl_projection_test.exs`,
  `test/smalt_graphlaw_matrix_test.exs`,
  `test/smalt_graphlaw_validator_test.exs`,
  `test/amqp/delivery_encoder_test.exs`, `test/amqp/fuzz_test.exs`,
  `test/amqp/primitive_codec_test.exs`,
  `test/amqp/management_rpc_test.exs`, `test/data_plane/kql_test.exs`. The
  2026-10-14 offender (`test/smalt_graphlaw_matrix_test.exs` starting its
  own Store under `async: true`) is RESOLVED: the file has zero Store
  references (its in-file comment documents the grep verification). No
  async+Store race remains.
- **`Store.clear()` in setup — 24 files, all `async: false`** (grep-verified
  2026-10-15): they do not race each other, and with the graphlaw matrix
  fix above no `async: true` module touches the shared Store. Current
  inventory: `test/smalt_services_test.exs`, `test/arm_error_corpus_test.exs`,
  `test/runtime_contracts_test.exs`, `test/egress_wiring_test.exs`,
  `test/azapi_actions_test.exs`, `test/smalt_egress_router_test.exs`,
  `test/apiversion_matrix_test.exs`, `test/strata_compat_test.exs`,
  `test/sb_children_test.exs`, `test/smalt_arm_gateway_test.exs`,
  `test/lro_test.exs`, `test/event_stream_test.exs`,
  `test/egress_dispatch_test.exs`, `test/route_negative_test.exs`,
  `test/security/security_hardening_test.exs`,
  `test/compliance/c1_arm.exs`, `test/compliance/c3_cosmos.exs`,
  `test/compliance/c4_blob.exs`,
  `test/data_plane/audit_planes_test.exs`,
  `test/data_plane/blob_hardening_test.exs`,
  `test/data_plane/key_vault_actions_test.exs`,
  `test/data_plane/blob_service_test.exs`,
  `test/data_plane/cosmos_test.exs`,
  `test/data_plane/conditional_headers_test.exs`.
- **Fixed substrate ports**: the wire tier (`test/wire/*_test.exs`) pins
  the default ports by design (that is the tier's contract). Outside the
  wire tier, listeners are ephemeral-port or Application-env driven
  (re-verified 2026-10-15): the compliance courts (c1..c7) probe free
  ports with `:gen_tcp.listen(0)`; `test/chaos/*` uses the
  Application-env contract (lawful); `test/data_plane/blob_service_test.exs`
  uses the shifted ports above; the amqp tier, `test/tls_test.exs`,
  `test/kv_tls_test.exs`, `test/metadata_endpoints_test.exs`,
  `test/eventgrid_conformance_test.exs`,
  `test/canonical_projection_test.exs`, and `test/mcp_wire_test.exs` boot
  their own listeners on ephemeral ports.
- `test/sdk-smoke/*` hardcodes substrate ports but is a separate
  Node-driven smoke tier that owns its substrate lifecycle — out of scope
  for `mix test` isolation.

## 5. Shared-state discipline

- **Kill-restart contract**: any test that takes a supervised child down
  (`Supervisor.terminate_child`, `restart_child`, or a supervised-child
  `Process.exit(pid, :kill)`) MUST restore it **synchronously in the test
  process** — `try/after` wrapping the kill window + a checked restart
  (`{:error, {:already_started, _}}` / `{:error, :already_present}` count
  as success, anything else `flunk`s) + a liveness wait + a state
  verification sweep (all named ETS tables `:ets.info/1 != :undefined`, via
  `Smalt.Store.table_names/0`) — before the test reports. An `on_exit`-only
  restore is a defect: `on_exit` runs in a separate ExUnit process after
  the test reports, so a test process that dies mid-window leaks the dead
  child process-wide. Reference: `test/pplan_test.exs` `restore_store!/0`
  delegating to `SmaltTest.Lifecycle.ensure_store_up/0`.
- **Killer inventory** (re-audited 2026-10-15): supervised-child kills are
  confined to `test/pplan_test.exs`; all other `Process.exit(..., :kill)`
  hits kill test-owned processes, and `test_helper.exs` kill-fallbacks in
  `Lifecycle.stop_shared_tree/0` are the sanctioned shared-tree stop path.
- **Shared-table cleanup** (success-path delete + `on_exit`): every test
  seeding rows into a SHARED ETS table (`:smalt_resources` et al.) cleans
  up on BOTH paths, deleting only its own prefix:

```elixir
on_exit(fn ->
  if :ets.info(@table) != :undefined do
    for key <- Smalt.Store.prefix_keys(@table, @prefix), do: :ets.delete(@table, key)
  end
end)
```

  Model: `test/store_churn_test.exs:17`. The prefix-scoped delete (not
  `delete_all_objects`) is the point — the table is shared. Whole-table
  wipe is allowed ONLY where the suite is the table's sole realistic tenant
  (the audit_planes quarantine, `test/data_plane/audit_planes_test.exs:25`).
  Non-vacuity: `scripts/shim_court/strata_cleanup_court.sh` proves the
  non-map-row leak reproduces when the cleanup is shimmed out. Read-path
  fence: `Smalt.Semantic.StoreRead` refuses non-map rows and vacuous
  identities TYPED, so contamination fails naming the table.

## 6. The isolation court (AZB-11)

`scripts/isolation_court.py` — `just isolation-court` (static) /
`just isolation-court-runtime` (`--runtime-only` twin). Stdlib-only,
fail-closed. It extends `gates/test_isolation_leak_gate.py`
(`just leak-court`) with:

1. **Inline exemptions**: a line carrying
   `# isolation-court: exempt <reason>` is removed from the scan (reason
   mandatory, counted in the receipt).
2. **`SmaltTest.Env.put_restored/1` counts as a fully-covered mutation**
   (save-prev + on_exit restore, structural), including the
   capture-then-delete shape (`put_restored(k: get_env(...))` followed by
   `delete_env` of the same key within two lines).
3. **start_link discipline**: a bare `GenServer/Agent/Task.start_link` (or
   any `start_link` with a literal `name:` option) in a test body must be
   `start_supervised!/1` (or `SmaltTest.Singleton.start_supervised_singleton!`,
   or an error-path assert). Exemption only via the inline marker.

Fail-closed: bare `put_env` with no restore must be REFUSED naming
file:line; clean save+on_exit discipline must PASS; `--self-check` proves
the same on real temp files including the exemption path. Exit 0 green /
1 offenders or vacuous / 3 self-check SKIP.

## 7. Runtime twin + exemption registry

`just isolation-court-runtime` boots the offline suite with
`SmaltTest.IsolationFormatter` (`test/support/isolation_formatter.ex`) and
`--max-cases 1` so per-module diffs of `Process.registered()` and
`Application.get_all_env(:smalt)` are race-free; any
`ISOLATION-TWIN LEAK module=...` line fails the court with the module name.

The registry `test/support/isolation_runtime_exemptions.exs` is the typed
exemption list for the runtime twin (AZB-11b), one entry per line:
`name <glob>  # reason: <text>`. Structural classes only: lib-owned lazy
singletons (`Smalt.Security.LedgerWriter`, `Smalt.Affidavit.WasmEngine*`,
`Smalt.Messaging.EventGrid`), kernel-owned VM-lifetime processes
(`:inet_gethost_native*`, `:dets`, `:dets_sup`), and shared-tree lazy
boot/teardown shifts (`Smalt.Store`, `Smalt.AmqpBroker*`, `Smalt.Plane.*`,
`Smalt.ArmGateway.LRO.*`, `Smalt.Telemetry.RollingCounters`,
`Smalt.Supervisor`, `Smalt.PPlan.Task`). The non-exemption law is the
point: **a leak block is exempt only when it has NO env delta and every
name delta matches a pattern — env leaks are never exemptable.** Every
entry cites its witness (the AZB-11 baseline log,
`tmp/isolation-court-runtime.out`, 26/153 modules leaked). Non-exempt
leaks still fail the court (fail-closed).

## 8. Canonical helpers

The helpers this contract is written against are one `use` away:
`use SmaltTest.Case` imports `AssertEventually`, `Env`, `Store`
(resilient), and `Singleton` — see
`docs/how-to/how-to-write-tests.md` for the worked usage.

## See Also

- `docs/TEST_ISOLATION.md` (historical audit ledger; section 5 carries the
  v26.10.16 ETS-contamination class receipts)
- `docs/how-to/how-to-write-tests.md` (canonical foundations)
- `docs/reference/courts.md` (gate + shim-court surfaces)
- `scripts/isolation_court.py`, `gates/test_isolation_leak_gate.py`
- `docs/jira/v26.10.18/receipts/azb-11-isolation-court.md`,
  `docs/jira/v26.10.18/receipts/azb-11b-leak-remediation.md`
