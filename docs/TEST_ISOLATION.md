# TEST_ISOLATION

# Smalt Test Isolation Contract

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
ownered exception — not a blanket skip. Re-enable a tier with
`mix test --include <tag>`.

| Tag | Meaning | Owner lane | Re-enable condition |
|---|---|---|---|
| `:amqp_wire` | Drives the real AMQP wire tier (real broker/listener on the AMQP port). Off by default so the plain `mix test` stays broker-independent. Carried by `test/compliance/c5_servicebus.exs` and the `test/amqp/` suites (`connection`, `management_rpc`, `pyamqp_parity`, `broker_facade`, `flow_credit` tests). | amqp wire tier | Broker available; run `mix test --include amqp_wire` |
| ~~`:arm_seam`~~ | **RETIRED 2026-10-15 (V261014-13)**: vacuous exclusion entry deleted from `test/test_helper.exs`; no test carries this tag; re-introduce only with a real named-gap test. `GAP(vacuous-tag-arm-seam)` CLOSED — token deleted | — | — |
| ~~`:dp_seam`~~ | **RETIRED 2026-10-15 (V261014-13)**: the re-enable condition landed (`Store.list_prefix/2` at `lib/smalt/store.ex:128`, used by `lib/smalt/data_plane/cosmos.ex:504,589`), no test carries the tag, and the cosmos fallback this row described is gone (If-Match replace is now one atomic `Store.compare_and_swap/4`); vacuous exclusion entry deleted from `test/test_helper.exs`; re-introduce only with a real named-gap test. `GAP(vacuous-tag-dp-seam)` CLOSED — token deleted | — | — |
| ~~`:closed_shape_gap`~~ | **RETIRED 2026-10-15**: the vacuous exclusion entry was deleted from `test/test_helper.exs` (store+graphlaw lane, cycle-6 receipt). No test carries this tag; re-introduce it only with a real named-gap test. | — | — |

## 4. Audit findings (re-audited 2026-10-15; 2026-10-14 snapshot superseded)

- `async: true` — 11 files (grep-verified):
  `test/dspy_test.exs`, `test/ocel_revops_test.exs`,
  `test/ocel_conformance_test.exs`, `test/shacl_projection_test.exs`,
  `test/smalt_graphlaw_matrix_test.exs`, `test/smalt_graphlaw_validator_test.exs`,
  `test/amqp/delivery_encoder_test.exs`, `test/amqp/fuzz_test.exs`,
  `test/amqp/primitive_codec_test.exs`, `test/amqp/management_rpc_test.exs`,
  `test/data_plane/kql_test.exs`. ALL are `Store`-clean — the 2026-10-14
  offender (`test/smalt_graphlaw_matrix_test.exs` starting its own Store under
  `async: true`) is RESOLVED: the file now has zero Store references (its
  in-file comment documents the grep verification) and `async: true` is safe.
  No async+Store race remains.
- `Store.clear()` in setup — 24 files (grep-verified 2026-10-15 lens-6; was
  23 — `test/data_plane/conditional_headers_test.exs` joined;
  `test/pplan_test.exs` was retired from this count — its setup installs a
  generalized spawn-leak tracer instead, see the leak-tracer section), all
  `async: false`, so
  they do not race each other, and with the graphlaw matrix fix above no
  `async: true` module touches the shared Store. Current inventory:
  `test/smalt_services_test.exs`, `test/arm_error_corpus_test.exs`,
  `test/runtime_contracts_test.exs`, `test/egress_wiring_test.exs`,
  `test/azapi_actions_test.exs`, `test/smalt_egress_router_test.exs`,
  `test/apiversion_matrix_test.exs`, `test/strata_compat_test.exs`,
  `test/sb_children_test.exs`, `test/smalt_arm_gateway_test.exs`,
  `test/lro_test.exs`, `test/event_stream_test.exs`,
  `test/egress_dispatch_test.exs`, `test/route_negative_test.exs`,
  `test/security/security_hardening_test.exs`,
  `test/compliance/c1_arm.exs`, `test/compliance/c3_cosmos.exs`,
  `test/compliance/c4_blob.exs`,
  `test/data_plane/audit_planes_test.exs`, `test/data_plane/blob_hardening_test.exs`,
  `test/data_plane/key_vault_actions_test.exs`, `test/data_plane/blob_service_test.exs`,
  `test/data_plane/cosmos_test.exs`,
  `test/data_plane/conditional_headers_test.exs`.
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