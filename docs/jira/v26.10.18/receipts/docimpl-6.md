# docimpl-6 — moduledoc audit (d8 re-run), 2026-10-18

**Standing: ALIVE** — 17-module d8 scope re-audited against current mechanisms
Context: solo(docs-audit d8 moduledoc re-audit greps; no mix test invocation)
(post LRO one-writer, post WasmEngine.Supervisor, post planes, post AZB-06/14
DETS, post AZB-07 Event Grid); 4 files fixed, docstring-only, zero behavior
change. Suites green. No git.

## Scope re-run (17 modules)

Audited `@moduledoc` of every file in the d8 scope against the live code
mechanism. Verified-current (no edit needed): `arm_gateway/lro.ex`,
`lro_notifier.ex`, `lro_sweeper.ex` (one-writer sweep/notifier statements
match the code exactly), `wasm_engine_supervisor.ex`,
`messaging/event_grid.ex` (lazy-start via AZB-09 child partition),
`messaging/amqp/connection.ex` (SASL ANONYMOUS / attach routing table match),
`messaging/amqp/atom_bridge.ex` (request-line sniff present at
`connection.ex:257-258`), `planes.ex` (runtime.exs `Smalt.Planes.resolve/0`
confirmed), `enclave/doctor.ex` verdict contract (check COUNT fixed, below),
`data_plane/blob_storage.ex` (`check_worm_arm/3` create/overwrite/delete arms
at :1597), `data_plane/cosmos.ex` (`Store.compare_and_swap/4` at :677/:780,
tables in `store_tables.ex`), `arm_gateway/router.ex` (versionless
`/operations/:op_id` at :2594), `projection/canonical.ex` (path fixed,
below), `egress_router.ex` (AZB-10 Peers moduledoc accurate), `auth/bearer.ex`
(exempt prefixes/exact list matches `@exempt_prefixes`/`@exempt_exact`).

## Fixes (mechanism statements only)

1. `lib/smalt/affidavit/wasm_engine.ex` — moduledoc fail-closed law predated
   the Part-1 supervisor: said "a dead engine returns
   `{:error, :engine_unavailable}`" as if unrestarted. Now states the engine
   is supervised (`WasmEngine.Supervisor`, child of
   `Smalt.Plane.ControlSupervisor`, confirmed at
   `lib/smalt/plane/control_supervisor.ex:31`); abnormal death is restarted
   by the owner; `:engine_unavailable` is the typed restart-window vocabulary.
2. `lib/smalt/enclave/doctor.ex` — moduledoc said "Four real checks"; code
   runs FIVE (`native_hcl_engine`, `store_invariants`, `wire_parity_gateway`,
   `host_transport`, `affidavit_wasm`). Fixed moduledoc + `run/1` @doc.
3. `lib/smalt/store/dets_mirror.ex` — `:tables` option doc said "default: the
   5 highest-value tables"; actual default is
   `Smalt.StoreTables.persisted_tables/0` (6 tables: smalt_blobs,
   smalt_cosmos_docs, smalt_event_messages, smalt_ledger_meta,
   smalt_ledger_transactions, smalt_resources — `store_tables.ex:210-217`).
4. `lib/smalt/projection/canonical.ex` — moduledoc named `docs/capability.json`;
   artifact is `docs/capabilities.json` (`@doc_path`, fence test
   `canonical_projection_test.exs:134-139`).

## Validation (real output)

Compile, `MIX_BUILD_ROOT=_build-lane7 mix compile --warnings-as-errors`:

```
     └─ (ggen_igniter 26.10.7) lib/ggen_igniter/gall_ticket.ex:277:11
     └─ (ggen_igniter 26.10.7) lib/ggen_igniter/semantic_a2a.ex:218:11
     └─ lib/smalt/plane/identity/sts_gate.ex:27:18
Compilation failed due to warnings while using the --warnings-as-errors option
```

All three warnings are PRE-EXISTING and outside this lane's scope (hex dep
`ggen_igniter` 26.10.7 + `plane/identity/sts_gate.ex`, not modified here;
absent from the session's diff: `git diff --stat -- lib/` shows only the 4
files above). Zero warnings from any touched file; touched modules compile
warnings-clean.

Suites covering the touched modules
(`mix test test/affidavit_wasm_engine_test.exs test/affidavit_wasm_failclosed_test.exs test/smalt_affidavit_wasm_test.exs test/canonical_projection_test.exs test/enclave_doctor_env_test.exs test/enclave_doctor_severity_test.exs test/store_dets_test.exs test/store_dets_growth_test.exs`):

```
Finished in 9.2 seconds (0.00s async, 9.2s sync)
59 tests, 0 failures (1 excluded)
```

Supervisor restart witnessed live in the same run
(`21:00:38.092 [warning] WasmEngine owner: engine died (:kill); restarting in-mailbox`)
— the new moduledoc statement is observation-backed, not prose.

Cleanup: lane build root `_build-lane7` deleted at integration (cleanup law).
