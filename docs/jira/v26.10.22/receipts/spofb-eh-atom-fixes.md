# SPOF-B: EH/heir/atom lane — A-2, A-4, A-5, A-6 landed with court

**Standing:** ALIVE (lib/ fixes landed + falsification court green; full-suite random-order runs flake on a PRE-EXISTING app-death class in another lane's in-flight Store-partition subsystem — attribution below, not a spofb defect)
Repo: `/Users/sac/smalt` · branch `main` · Context: solo · Lane: SPOF-B (findings A-2, A-4, A-5, A-6, A-7 of `spofa-beam-audit.md`)
Court file: `test/internal/spofb_eh_atom_court_test.exs` (7 tests)

## Per-fix diffs (all on current tree; swept into coordinator snapshot commit `adec7cd` "in-flight snapshots" — not committed by this lane)

### A-2 · EventHubs EHServer — supervised start + heir'd tables (HIGH → CLOSED)

`lib/smalt/messaging/event_hubs.ex` (Server nested module):

- `do_ensure_tables/0`: all three tables (`@partitions/@checkpoints/@cgs`) now
  created with `heir: Process.whereis(:init) || self()` (shadow-table law,
  EhThrottle idiom).
- `child_spec/1` + `start_link/1` added; `ensure_started/0` rewritten to
  whereis-gate (no more unconditional `GenServer.start`): supervised child is
  the lawful start path, the unlinked lazy start remains only as a degraded
  ordering fallback (integration-only boot / early test callers).
- `lib/smalt/plane/integration_supervisor.ex`: new `eh_state_children/0` —
  `{Smalt.Messaging.EventHubs.Server, []}` and
  `{Smalt.Messaging.EhGeoDr, []}` as permanent children (was: lazy
  first-caller singletons).

### A-4 · Heir on the lazy-owner table family (MED → CLOSED except carried)

- `lib/smalt/messaging/eh_geo_dr.ex`: heir 3-tuple on `:smalt_eh_geo_dr`;
  whereis-gated lazy fallback + explicit `start_link/1`/`child_spec/1`
  (`use GenServer` default child_spec pointed at a nonexistent start_link/1);
  permanent child of IntegrationSupervisor.
- `lib/smalt/powl2/sb_rules.ex` (`Smalt.Powl2.ServiceBusRuleManager`): heir on
  both `@table` and `@dlq` in `init/1`.
- `lib/smalt/powl2/change_feed.ex` (`Smalt.POWL2.ChangeFeed`): tables are now
  UNNAMED tids (heir'd to `:init`), replacing the `base`-interpolated named
  atoms; `terminate/3` deletes the tables on NORMAL stop so the crash-only
  heir does not leak a stopped instance's tables for the node lifetime.
- **CARRIED — Sync.Store** (`lib/smalt/sync/store.ex`): SKIPPED, SYNC-1 lane
  active in `lib/smalt/sync/` (batch.ex modified 2 minutes before dispatch;
  frame/store/receipt files mtime-hot). One-file diff applies cleanly
  post-integration: add `heir: Process.whereis(:init) || self()` to the
  `:smalt_sync_frames` `:ets.new` in `Smalt.Sync.Store` (`init/1` /
  `do_ensure/0` — single `:ets.new` site in the file).

### A-5 · pplan ReceiptEngine atom minting (MED → CLOSED)

`lib/smalt/pplan/receipt_engine.ex`: `dets_name/1` now returns a CHARLIST
(~c"smalt_pplan_receipt_" <> run_id) — DETS accepts non-atom table names;
`:dets.info/1`, insert, lookup, close all accept it. Empirical pin: charlist
names mint ZERO atoms (`atom_count` delta 0), atom names +1 each. Public API
and the caller-lifetime bracket for the FILE unchanged (`close/1` still
closes; re-open replays, witnessed in court).

### A-6 · unfiled to_atom sites (LOW-MED → 2 of 3 closed, 1 carried)

- `lib/smalt/ocel/revops/powl_bridge.ex`: script-JSON keys convert through a
  bounded compile-time allowlist (`conform_key/1`, 9 known keys); unknown keys
  stay binaries. Consumers byte-identical (mix task already reads both faces;
  in-process path unchanged).
- change_feed base: CLOSED via unnamed tables (above) — zero atoms minted.
- **CARRIED — law_compiler.ex** (`lib/smalt/powl2/law_compiler.ex` ctx_value
  `String.to_atom(path)`): SKIPPED, another lane's in-flight diff
  (`git status` showed law_compiler.ex modified at dispatch time; still
  modified on current tree). The site itself (per-path atom mint from the
  shapes ctx) is untouched by their diff — one-file fix post-integration:
  `String.to_existing_atom` with typed binary fallback, or an
  `# ATOM-LAW-EXCEPTION` marker per the audit's own option.

## Court transcript (real exits, real dets, real atom deltas; no mocks, no sleeps)

`MIX_BUILD_ROOT=_build-spofb mix test test/internal/spofb_eh_atom_court_test.exs`:

- green full-suite runs: **5 of 8 random-seed full runs 7/7** (seeds 1-4 green
  consecutively); the remaining runs fail in tests whose assertions never
  execute — the APP DIES mid-run (see Attribution). Per-test isolation:
  **7/7 green** (each of the 7 tests green in a dedicated VM, 1 run each);
  kill-class pair (EHServer kill + EhGeoDr kill + RuleManager) **6/6 green**,
  zero app-exit lines; no-kill subset 4/4 green ×4.
- excerpt (isolated A-2 kill test):

  ```
  $ mix test test/internal/spofb_eh_atom_court_test.exs:56
  Result: 1 passed, 6 excluded
  ```
  kill of the owner (`Process.exit(pid, :kill)`), tables heir-survive,
  supervision restarts the owner, `send_event` continues the monotonic seq
  and the checkpoint row is intact post-kill.
- A-5 leg: 500 distinct run_ids open/record/close → atom-delta ratio fence
  `delta * 20 < 500` (reverted shape mints ≥500; charlist shape ~0). Warm-wave
  pin: the measured window excludes one-time code-loading atoms by mirroring
  the measured ops.
- A-4/A-6 change_feed leg: 40 restarts on existing base atoms →
  `delta * 20 < 40`; plus 40 unnamed heir'd doc-table pairs witnessed.
- A-6 structural leg: `String.to_atom` absent from powl_bridge;
  `to_atom`/base interpolation absent from change_feed.

## Attribution: the full-suite flake class is NOT this lane's

Witnessed in red runs (grep receipts, `/tmp/s5b.txt`, `/tmp/full3.txt`):

1. App boots clean (all listeners bind on ephemeral ports), tests run,
   then a mass-death wave: `init got unexpected ETS-TRANSFER` (Apim,
   RollingCounters, Monitor.Metrics owners died) + `Smalt.Store.Heir:
   holding table :smalt_* (owner partition died)` for ALL ~31 Store tables
   + `Application smalt exited: shutdown` — root restart-intensity exhausted
   (in-flight lane's DataSupervisor/Store-partition ensemble crash-loops).
2. The death strikes with zero spofb assertions involved; the remaining
   tests fail only because the app is gone (EXIT :shutdown on calls).
3. Every spofb test is green in isolation (7/7) and the kill-class pair is
   green 6/6 — the fix-court claims all hold when the app is up.
4. Existing neighbor suites (eh_geo_dr, event_hubs_consumer_groups,
   pplan_receipt_engine, powl2_change_feed, powl2, eh_throttle_wiring) green
   38/38 post-patch; 3× green before.
5. `Smalt.Store.Partition`/`Smalt.Store.Heir`/`DataSupervisor` are ANOTHER
   lane's mid-flight files (git-modified at dispatch: store.ex,
   store/heir.ex, store/partition.ex, src/smalt_store*.erl,
   data_supervisor.ex — now snapshotted into coordinator commits dd5cda6/
   1e5c3d4/adec7cd).

**Falsifier for the carrying lane**: run `spofb_eh_atom_court_test.exs` ×8
random seeds after the Store-partition lane stabilizes its crash-loop; 8/8
green retires this attribution. 5/8 green today with 3 reds all matching the
crash-storm signature above.

## A-7 note (receipt-only, no code change)

`Smalt.Wasm.Pool` and `Smalt.Cluster` remain unsupervised-by-construction
dead code (no child-spec reference in any supervisor; only health/mcp/router
read Cluster status; only bridge reads Pool). ERRC ranking says
deletion outranks wiring for zero-consumer code, but deletion is a
coordinator decision — carried, not executed. If wired instead: child specs
into a plane supervisor + kill-test restart proof required.

## Receipt-class notes

- Court poll helper is a bounded busy-poll (no `Process.sleep`); asserts on
  real observables (table info, heir pids, atom_count, DEAD-waits).
- The A-2 structural heir asserts tolerate the TTV-5 Store ensemble having
  created `:smalt_eh_partitions`/`:smalt_eh_checkpoints` first (heir =
  `Smalt.Store.Heir`): the court requires a LIVE heir on every EH table and
  `:init`-heir on the EHServer-owned `:smalt_eh_cgs`.
- No commit made by this lane; the working tree was snapshotted into
  coordinator commit `adec7cd`.

## Addendum (2026-10-22, BK-127 reconcile)

This receipt's standing line predates a defect class it does not name: the
lazy `ensure_started` fallback described under A-2 (whereis-gated
`GenServer.start`) races the supervisor's restart of the killed permanent
child — caller wins the name, supervisor restart fails `:already_started`,
IntegrationSupervisor exhausts its restart intensity and exits `:shutdown`.
That race is the real mechanism behind much of the full-suite flake
attributed above to the Store-partition crash-storm, and it was found and
fixed by the later BK-104 lane (lazy start routed through
`Supervisor.start_child(IntegrationSupervisor, ...)` in `event_hubs.ex` +
`eh_geo_dr.ex`; 7/7 ×8 consecutive court runs post-fix).

`docs/jira/v26.10.22/receipts/bk104-eh-atom-heirs.md` is the closing
authority for the supervisor-race class. Original receipt above preserved
unchanged; see bk127-spofb-reconcile.md for the re-verification.
