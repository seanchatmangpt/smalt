# i27 — deterministic pair (v2-soak) + pplan lens7 extension

Standing: ALIVE (all target tests red-then-green, 3x green repeat, neighbor suites green)
Context: slice(target deterministic-pair files, _build-ft-det, 3x green) + full (wave full offline mix test, 2710 tests / 7 failures — disclosed)

Lane: i27 deterministic pair. Repo: /Users/sac/smalt. Build root: `_build-ft-det`.
Private ports 39711-39716 (a foreign lane substrate held the default ports;
test.exs `SMALT_TEST_*` env overrides used for all runs).

## Scope

Two deterministic faces from v2-soak, plus a coordinator mid-task scope addition
(third face, same root cause as face 2):

1. **EnclaveStateTest destroy residue** — after `State.destroy/1`, the
   `:smalt_sb_queues` table retained `["resourcewritesuccess"]`.
2. **McpTest :420 + McpWireTest :806** — `doctor.summary` child list missing
   `Smalt.Store` (AZB-09 plane restructure: Store moved under
   `Smalt.Plane.DataSupervisor`; the summary listed only root children).
3. **pplan lens7 (`test/pplan_test.exs` ~:2889)** —
   `Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)` →
   `{:error, :not_found}` (same AZB-09 root cause). Coordinator-directed
   extension.

## Root cause + fix, per face

### Face 1 — enclave destroy residue (`lib/smalt/enclave/state.ex`)

The AZB-10 resource-write fan-out
(`Smalt.EgressRouter.Peers.emit_resource_write_success/2`, called from
`lib/smalt/arm_gateway/router.ex` on resource PUT) enqueues every
ResourceWriteSuccess event on the Service Bus bridge queue
`"resourcewritesuccess"` — a queue row (+ `{queue, :seq}` counter) in
`:smalt_sb_queues` and message rows in `:smalt_sb_messages`. The queue is
auto-created by the enclave's own control-plane writes, never ARM-declared, so
the router's ARM cascade can never reach it.

Decision per product contract (enclave destroyed ⇒ its queues gone): extend
the destroy sweep. Added `purge_resource_write_bridge/0` to
`Smalt.Enclave.State.destroy/1` (after the metrics cascade, before residue):

```elixir
defp purge_resource_write_bridge do
  bridge = "resourcewritesuccess"

  # message rows are keyed {queue, seq}; the seq counter is {queue, :seq}
  :ets.match_delete(:smalt_sb_messages, {{bridge, :_}, :_})
  Store.delete(:smalt_sb_queues, bridge)
  Store.delete(:smalt_sb_queues, {bridge, :seq})
  :ok
end
```

Not a metadata-table exclusion: `:smalt_sb_queues` is resource-bearing
(`metadata_only: false` in the generated `Smalt.StoreTables`), and the
contract says the destroyed enclave's queues are gone.

### Face 2 — doctor.summary plane-aware (`lib/smalt/mcp/router.ex`)

The tree is legitimately plane-dependent (AZB-09): Store is one level below
the root. Made `doctor_summary/0` tree-aware instead of patching the test
expectation:

- `flatten_children/2` walks the configured supervisor (default
  `Smalt.Supervisor` root), descending into `:supervisor`-typed, live-pid
  children (bounded depth 3), exit-guarded so a dead/non-supervisor subtree
  degrades to that plane's own row.
- Nested children carry a `"plane"` field (sanitized parent id).
- Only `:supervisor`-typed children are descended into, so the lens-4
  hostile-id fuzz supervisor's `:worker` Task children are never signalled
  (`mcp_test.exs:936` passes unchanged).

### Face 3 — pplan lens7 + shared helper (`test/pplan_test.exs`, `test/support/lifecycle.ex`)

- `SmaltTest.Lifecycle.store_owner/0` (new): tree-aware probe of
  `[Smalt.Supervisor, Plane.Data/Control/Integration/IdentitySupervisor]`;
  returns the supervisor whose child list contains `Smalt.Store`, or nil.
- lens7's terminate/restart/on-exit call sites target
  `store_owner()`; `Lifecycle.restart_store_child/0` also resolves via
  `store_owner()` (root fallback when planes absent).

## Red -> green evidence

Red at session start (all three faces; the two doctor tests were the
session-initial runs, 3 failures / 6 tests):

```
6 tests, 3 failures (83 excluded)
```

Structural red proof for face 3 (post-fix resolver sanity, MIX_ENV=test):

```
iex> Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)
{:error, :not_found}
iex> SmaltTest.Lifecycle.store_owner()
Smalt.Plane.DataSupervisor
```

Green — target pair + pplan, 3x:

```
=== PAIR RUN 1 ===
79 tests, 0 failures (83 excluded)
=== PAIR RUN 2 ===
79 tests, 0 failures (83 excluded)
=== PAIR RUN 3 ===
79 tests, 0 failures (83 excluded)
```

Green — neighbors (enclave/mcp/wire/queue-store/store-tables/topology/telemetry):

```
174 tests, 0 failures (4 excluded)
141 tests, 0 failures (4 excluded)
```

## Regression sweep + residual classification (discipline: pre-existing vs session-introduced)

Full offline `mix test` during the wave: `2710 tests, 7 failures` then a rerun
showed `9 failures, 1 invalid`. Classification sweep:

- `test/azsim/dr_scenarios_test.exs` + `test/egress_dispatch_test.exs` +
  `test/error_codes_doc_test.exs` rerun together with my changes live:
  `118 tests, 1 failure` — the only failure was ERROR_CODES.md drift.
- `docs/ERROR_CODES.md` was stale **from other lanes' in-flight
  `arm_gateway/router.ex` line shifts** (not my files). Regenerated per the
  generated-artifact convention: `python3 scripts/gen_error_codes.py` →
  `wrote /Users/sac/smalt/docs/ERROR_CODES.md (109 rows)`; doctest now
  `7 tests, 0 failures`.
- `test/azsim/azure_common_issues_test.exs` is **compile-blocked in the
  working tree by another lane's in-flight edit** (requires
  `/burn-evidence/test/support/assert_eventually.ex`, enoent in this
  checkout). Not my surface; not classified green. Flagged as a cross-lane
  residual for the azsim lane / coordinator.
- Earlier full-run DR-scenario failures did not reproduce in the isolated
  rerun (port contention with the foreign substrate is the suspected cause);
  disclosed, not claimed green beyond the isolated run.

## Files touched

- `lib/smalt/enclave/state.ex` — bridge-queue purge in destroy
- `lib/smalt/mcp/router.ex` — plane-aware doctor.summary flatten
- `test/support/lifecycle.ex` — `store_owner/0` + owner-resolved restart
- `test/pplan_test.exs` — lens7 terminate/restart targets the owner
- `docs/ERROR_CODES.md` — regenerated (other lanes' line drift)

## Replay

```
SMALT_TEST_ARM_PORT=39711 SMALT_TEST_ARM_TLS_PORT=39712 SMALT_TEST_EGRESS_PORT=39713 \
SMALT_TEST_AMQP_PORT=39714 SMALT_TEST_EVENT_HUBS_PORT=39715 SMALT_TEST_MCP_PORT=39716 \
MIX_BUILD_ROOT=_build-ft-det mix test \
  test/enclave_state_test.exs test/mcp_test.exs:420 test/mcp_wire_test.exs:806 test/pplan_test.exs
# expect: 79 tests, 0 failures (83 excluded)
```

## Falsifiers

- Enclave PUT baseline (which enqueues a bridge row) followed by
  `State.destroy/1` reports residue in `:smalt_sb_queues` → this receipt is
  refuted.
- `doctor.summary` over the live all-planes tree lists no child with
  `id == "Smalt.Store"` → refuted.
- `Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)` is the lens7
  contract → refuted (owner is DataSupervisor; the test now resolves it).

## Disclosures

- Coordinator-owned git: my four file edits landed in coordinator commit
  b2c53b3 mid-session; the receipt file and the ERROR_CODES regen are
  session-tail working-tree state.
- A baseline swap attempt (snapshot via `git show HEAD:path` swap, no stash)
  for the failing azsim subset was aborted because other lanes' in-flight
  edits span those files; classification was done live instead.
- No lane build roots created beyond the assigned `_build-ft-det`.
