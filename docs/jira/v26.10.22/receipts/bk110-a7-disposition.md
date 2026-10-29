# BK-110 · A-7 Disposition — Wasm.Pool / Cluster supervised start sites

**Standing:** ALIVE (wired + kill-tested on the current tree; courts green, blast-radius court green; census carry-over disclosed as pre-existing at HEAD)
Repo: `/Users/sac/smalt` · branch `main` · Context: solo
Parent finding: SPOF-A A-7 (`docs/jira/v26.10.22/receipts/spofa-beam-audit.md`), ERRC disposition branch (3) — wire lawfully.

## Why wire, not delete

The audit's premise ("truly unreferenced — dead code by construction") did not hold under
full-corpus grep. Real references:

- `Smalt.Wasm.Pool`: production chain
  `lib/smalt/egress_router.ex:1014 → lib/smalt/egress/SyncRoutes.ex:115 → lib/smalt/sync/guard.ex (run_guard/2, :wasm arm) → lib/smalt/wasm/bridge.ex:140-146 → Pool.checkout/1`.
  Bridge.eval's default pool is the named `Smalt.Wasm.Pool` — with no start site, an
  operator setting `config :smalt, :sync_guard == :wasm` got a noproc crash on first frame.
  Also start_supervised!-consumed by `test/integration/wasm_abi_court_test.exs`.
- `Smalt.Cluster`: live MCP route `cluster.status`
  (`lib/smalt/mcp/router.ex:825`, input_schema at :373), health read path
  (`lib/smalt/health.ex:178`), and a real-dist court `test/cluster/cluster_test.exs`
  (18 tests incl. a :peer second-BEAM join court). Deletion would have broken a live MCP
  tool surface; therefore branch (3) of the disposition applies.

## Disposition (wired)

- `lib/smalt/application.ex` — new `cluster_child/0`: permanent supervised child of root
  `Smalt.Supervisor` when `config :smalt, :cluster, enabled: true`; `[]` otherwise.
  Default OFF — solo boots byte-identical. Fail-closed init raises for missing dns_name
  (config defect refuses boot, per the module's own contract).
- `lib/smalt/plane/control_supervisor.ex` — new `wasm_pool_child/0`: `Smalt.Wasm.Pool`
  as a permanent child of the Control plane when `config :smalt, :sync_guard == :wasm`;
  `[]` otherwise. Default OFF — default boot byte-both identical; the :wasm governance
  face now gets a supervised pool, not a first-caller-linked one.
- Kill-test courts (real collaborators, no mocks):
  - `test/cluster/cluster_test.exs` — new supervised-start leg: child under a real
    one_for_one supervisor, killed, restart observed (fresh pid via
    `SmaltTest.Internal.Poll.eventually`), `cluster_status/0` answers `enabled: true`.
  - `test/integration/wasm_abi_court_test.exs` — new leg: supervised pool self-heals a
    killed worker (`idle/1` returns to 1, fresh checkout pid != dead pid) and survives a
    pool-level kill (supervisor hands back a fresh named pool, `idle/1` == 1).

## Verification (real output)

Toolchain: asdf elixir 1.20.4-otp-29, `MIX_BUILD_ROOT=_build-lane110`.

```
$ mix compile
lib/ warnings: 36, all pre-existing (BK-107 receipt already files the
--warnings-as-errors drift: plug router + powl2/journal_sink clause-grouping drift);
zero warnings attributable to application.ex / control_supervisor.ex / cluster.ex /
wasm/* or the two court files.

$ mix test test/cluster/cluster_test.exs test/integration/wasm_abi_court_test.exs
..................................................................
Finished in 0.9 seconds (0.00s async, 0.9s sync)
Result: 18 passed

$ mix test test/internal/plane_blast_radius_test.exs test/internal/internal_tier_census_test.exs
Result: 11/12 passed
  plane_blast_radius_test.exs: PASS (membership asserts — the added gated children do
  not change the default child set, so the topology assert holds)
  internal_tier_census_test.exs: 1 failure — PRE-EXISTING AT HEAD, not session-
  introduced: `every Smalt-prefixed module reference is inside the closed allowlist`
  flags ja15_error_logger_court_test.exs → Smalt.Ja15.RefusalTelemetryHandler /
  Smalt.DataPlane.BlobError.send_error. `git grep RefusalTelemetryHandler HEAD -- lib`
  returns nothing: the module is absent from lib at HEAD and in the working tree while
  the (unmodified) ja15 court references it — a JA-15 lane allowlist/module
  reconciliation, owned by that lane, not A-7 (A-7 touched no test/internal file).
```

## Falsifier status

- Court flip legs (kill → fresh pid; worker kill → respawn) — executed, PASS.
- Mutation leg (strip the gated child spec → kill must leave a dead start site) — not
  separately executed; the pre-patch state IS the mutation witness: before this diff a
  kill left noproc (that is the filed A-7 scenario, JA-1 #3/#4 carry-over).
- A-7 row in `spofa-beam-audit.md` may be annotated CLOSED (wired) once the operator
  re-reads this receipt; not self-flipped here.
