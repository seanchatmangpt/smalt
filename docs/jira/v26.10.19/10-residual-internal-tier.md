# V261019-10 — Residual internal Elixir tier: five fresh test/internal/ files re-derived from lib ground truth

> **Status at materialization (2026-10-19):** IN FLIGHT — `test/internal/` holds
> `plane_blast_radius_test.exs`, `vm_zero_growth_test.exs`, `poll_helper.exs`;
> wasm/dets/census-guard files pending from the residual lane.

- **Release:** v26.10.19
- **Lane:** residual-elixir-tier
- **Base:** clean-room reset at HEAD `4fd2ff2ba80e618341dc85de3ef84fcb8702bff3` (post-deletion tree)
- **Status:** draft — ready-for-work once the deletion gate (V261019-11) has landed

## Objective

After the clean-room reset removes the 303 tracked `test/` files, the internal
tier must be rebuilt from ZERO — nothing copied from the deleted tests, every
assertion re-derived from `lib/` ground truth read fresh at the post-deletion
HEAD. This WO owns exactly five new files under `test/internal/`:

| File | lib ground truth it re-derives |
|---|---|
| `test/internal/plane_blast_radius_test.exs` | `lib/smalt/plane/*_supervisor.ex` subtree isolation |
| `test/internal/vm_zero_growth_test.exs` | `Smalt.Store` ETS row-count stability at idle |
| `test/internal/wasm_nif_lifecycle_test.exs` | `Smalt.Affidavit.WasmEngine` + `WasmEngine.Supervisor` lifecycle |
| `test/internal/dets_mirror_recovery_test.exs` | `Smalt.Store.DetsMirror` AZB-14 typed recovery vocabulary |
| `test/internal/internal_tier_census_test.exs` | Non-Duplication enforcement over the tier itself |

Shared posture for all five (NO-SLEEP-DOCTRINE applies, per
`docs/jira/v26.10.18/receipts/b8-doctrine.md`): **zero `Process.sleep/1`** —
all liveness is polled with `assert_eventually`-style typed retry or synchronous
GenServer calls. All files use `async: true` unless a file needs the shared
Store (then `async: false` with a stated reason).

## Files owned (this lane)

All five files above, plus nothing else. NOT owned: `lib/` (read-only ground
truth for this lane), `test/test_helper.exs`, Justfile recipes.

## Tasks

### Task 1 — `plane_blast_radius_test.exs`

Re-derive from `lib/smalt/plane/control_supervisor.ex`,
`data_supervisor.ex`, `identity_supervisor.ex`, `integration_supervisor.ex`
(read them fresh; do not recall prior test behavior):

1. For each plane supervisor, assert the child list matches the documented
   moduledoc (Control: 2 Bandit listeners + LRO Notifier + LRO Sweeper +
   WasmEngine.Supervisor; `one_for_one`, `max_restarts: 5, max_seconds: 5`).
2. Blast-radius law: `terminate_child` on a non-Store plane child (e.g.
   `Smalt.ArmGateway.LRO.Notifier` in the control subtree) does NOT take down
   siblings under `:one_for_one` — after the kill, the sibling pids are
   unchanged. Restore via supervisor restart (bump restart intensity only via
   the supervisor's own policy; never `Application.stop(:smalt)`).
3. Plane identity: `Smalt.Planes.resolve/0` returns only known planes
   (`Planes.known/0`); an unknown plane atom is refused typed.

Recovery posture: use `SmaltTest.Lifecycle.ensure_store_up/0`-equivalent
post-deletion helper (test_helper is rebuilt by lane 09/heir; this lane only
calls the shared helper, never repairs the tree inline).

### Task 2 — `vm_zero_growth_test.exs`

Law under test: **the VM does not grow when nobody writes.** Derived from
`Smalt.Store` + `Smalt.StoreTables`:

1. Snapshot `:ets.info(table, :size)` for every table in
   `Smalt.StoreTables.persisted_tables()` while the store is hot and idle.
2. Hold for a bounded idle window — the window is bounded by N synchronous
   no-op `GenServer.call(Store, ...)` rounds (a real call, not a sleep), e.g.
   50 rounds of a cheap typed read (`Smalt.Store` read of a probe key).
3. Re-snapshot sizes; assert byte-identical counts (zero growth, zero
   shrink). A leak in a periodic process (LRO Sweeper, DetsMirror tick) shows
   up here as table growth without writes.
4. Also assert process-count stability: `length(Process.list())` before vs
   after the idle window is within a small typed tolerance (0 net new named
   processes; any new pid must be unnamed/transient, witnessed twice).

### Task 3 — `wasm_nif_lifecycle_test.exs`

Re-derive from `lib/smalt/affidavit/wasm_engine.ex` and
`.../wasm_engine_supervisor.ex` public surface only:

1. Typed-down face: when the engine is not running,
   `WasmEngine.call/2` returns the `@engine_unavailable` typed value, never a
   raise (witness `call(nil, req)` path directly).
2. Lifecycle: `Supervisor.terminate_child(Smalt.Plane.ControlSupervisor,
   Smalt.Affidavit.WasmEngine.Supervisor)` then `restart_child` — engine
   comes back; `WasmEngine.Supervisor.engine_running?/0` flips false→true and
   `restore_owner/0` behaves per its @doc.
3. `last_init_refusal/0` / `reset_last_init_refusal/0` contract: refusal is
   `:none` on a clean boot; a forced init refusal is witnessed in
   `last_init_refusal` until reset.
4. `call_admit_and_seal/4` typed-down: engine down ⇒ typed
   unavailable witness on the sideband, HTTP 2xx-shaped caller contract
   preserved (no crash propagates).
5. Supervisor passthrough fence: double-start of the WasmEngine supervisor
   child spec returns `{:error, {:already_started, _}}` passthrough, not a
   crash loop (witnessed fence-12 shape, re-derived from supervisor code).

### Task 4 — `dets_mirror_recovery_test.exs`

Re-derive from `lib/smalt/store/dets_mirror.ex` moduledoc + `open_typed/3`
behavior (lines ~181+; the moduledoc IS the spec):

1. Clean path: `start_link(dir: tmp)` with `repair: false` on synced files —
   opens byte-exact (AZB-06 leg).
2. `needs_repair` path: kill -9-equivalent (close the file without `:dets.close`
   via a raw `:dets.open` in a tmp dir, or open with a torn header) ⇒ boot
   probe with `repair: false` yields `{:error, {:needs_repair, _}}`; with
   `repair: true` the file reopens and telemetry
   `[:smalt, :store, :dets_repaired]` fires exactly once per repaired table.
3. Typed refusals: a flipped-header file (`:not_a_dets_file`) with
   `repair: true` ⇒ `{:error, {:store_corrupt, table, path, reason}}`;
   with `repair: false` a torn file stays
   `{:error, {:corrupt_mirror, table, path, reason}}`. Neither crashes the
   caller untyped.
4. `start_link` up-front validation: a corrupt mirror file raises
   ArgumentError naming table + path + tag (fail-closed boot leg, per the
   `Enum.each` validation block) — never a runtime silent repair.
5. `restore/0` idempotence: rows already in ETS are skipped; counts map
   reports only rows restored by this call; ETS wins while hot.

### Task 5 — `internal_tier_census_test.exs` (Non-Duplication enforcement)

This is the tier's own guard, modeled on the surviving
`test/stress_tier_census_test.exs` structural fence (file-read census, no
runtime effects), but enforcing NON-DUPLICATION instead of population:

1. **Forbidden tokens:** scan `test/internal/*.exs` for tokens that indicate
   copied-from-deleted-tests content. The forbidden list (asserted to have
   zero hits) includes, at minimum:
   - `Process.sleep` (NO-SLEEP-DOCTRINE)
   - `Application.stop(:smalt)` (shared-tree killer; the documented
     canonical_projection defect class)
   - `restore_app()` conditional-heal idiom (`Process.whereis(Smalt.Store)`
     guarded one-liners — the broken heal shape)
   - verbatim test-name strings from the deleted suites (spot list pinned in
     the file with a comment; any hit means content was copied, not
     re-derived)
2. **Observables allowlist:** the only `lib/` modules these five files may
   reference are: `Smalt.Store`, `Smalt.StoreTables`,
   `Smalt.Store.DetsMirror`, `Smalt.Planes`, the four
   `Smalt.Plane.*Supervisor` modules, `Smalt.Affidavit.WasmEngine`,
   `Smalt.Affidavit.WasmEngine.Supervisor`, and the shared test-helper
   lifecycle module. Any other `Smalt.` reference in `test/internal/` fails
   the census — the tier tests a closed, enumerated surface.
3. **Population floor:** `test/internal/` must contain exactly the five
   owned files (fence against silent file loss, same falsifier shape as the
   stress tier census: delete a file ⇒ this test fails).
4. File-read only (`File.read!` + regex), `async: true`, no app-tree side
   effects — the census must be safe to run in any position.

## Non-Duplication provenance rule

Every assertion must cite its lib source in a comment
(`# derived from lib/smalt/store/dets_mirror.ex moduledoc AZB-14 section`),
not from memory of the deleted tests. A reviewer (and the Task-5 census)
checks that no deleted-test artifact (names, magic literals, helper idioms
from the old suites) appears.

## Close conditions

- `MIX_BUILD_ROOT=_build-ft-res1 mix test test/internal/` — 5 files, 0
  failures, 0 skips, run TWICE with identical pass sets (local court-x2).
- `grep -rn "Process.sleep" test/internal/` → 0 hits.
- `just compile` / `mix compile --warnings-as-errors` exit 0.
- The census fence is falsifier-witnessed: temporarily deleting one internal
  file (or injecting a forbidden token) turns the census red, then green
  after revert — witnessed in the lane receipt.
- Receipt filed at `docs/jira/v26.10.19/receipts/v10-residual-tier.md`.
