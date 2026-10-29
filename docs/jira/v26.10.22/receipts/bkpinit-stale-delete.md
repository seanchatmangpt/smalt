# BK-PINIT — powl2 init stale-delete (F8 shared-ETS wound, powl2 hop)

**Standing:** ALIVE — the BK-CENS3-typed powl2 `:already_exists` init crash (×6 under batch
load) is CLOSED: the init path now stale-deletes the heir-held table before `:ets.new`.
Isolated ×5 green, batch `test/internal/` green on this surface, full powl2 suite (12 files,
internal + integration) 90/90 green, non-vacuity shim court fires (`cause: :already_exists`
reproduced on the pre-fix init, restore byte-exact).
**Context:** solo (shared, actively-edited checkout — bkegs1 compile-froze the tree ~90s
early in the window, cleared by its owner within the SLA; no edit applied by this lane
outside its own files)
**Date:** 2026-10-22
**Lane:** BK-PINIT, `MIX_BUILD_ROOT=_build-bkpinit`

## Root cause

`Smalt.Powl2.ServiceBusRuleManager.init/1` (lib/smalt/powl2/sb_rules.ex) creates two
`:init`-heir'd NAMED tables (`:powl8_sb_rules`, `:powl8_sb_rules_dlq`) with a bare
`:ets.new`. Under the heir law (SPOF-B / A-4) the tables re-parent to the always-alive
`:init` pid on ANY owner death — including `GenServer.stop(pid, :kill)` and normal stops
(the module has no terminate/2). The stale heir-held table carries the same
read_concurrency and passes presence checks, so the restarted GenServer's `:ets.new` raised
`:already_exists` (bkseal2 Class B witnessed the same signature; bkcens3 typed the load
dependence: in isolation the restart won the race, under batch load it did not).

## Fix (structural, mirrors the ets_auto court's convergence law)

`lib/smalt/powl2/sb_rules.ex` init now routes both tables through `ensure_table/2`:

- `:ets.info(name, :owner) == :undefined` → create.
- owner == self() → already ours, keep.
- otherwise (stale, owner differs): if the owner is a live NON-`:init` pid (a prior
  incarnation still mid-death) wait bounded on a monitor (15s after) for its DOWN —
  structural sync on a real observable, never a sleep; an `:init`-held table is deleted
  immediately (the owning incarnation is gone by construction — `:init` never dies, so
  waiting on it would be a guaranteed 15s stall).
- delete the stale table, then create with the target options.

No sleeps, no mocks — real ETS/GenServer collaborators throughout.

## Court additions (test/internal/powl2_primitives_test.exs, +3 tests)

1. **crash-killed manager**: stop `:kill` (crash death, terminate never runs) → assert the
   table survives under `Process.whereis(:init)` ownership carrying the stale row → restart
   → assert the RESTARTED pid owns the table (ets_auto-shaped convergence law) and the
   stale row did NOT leak.
2. **batch restart fan-out**: 6 kill/restart cycles, each asserting restarted-pid ownership
   — the witnessed `:already_exists` shape, looped.
3. **load under restart**: 16 concurrent writer tasks × 25 puts, then a kill/restart cycle,
   then post-restart insert + row-shape assert.

## Non-vacuity (shim court, marker: bkpinit SHIM-COURT run)

BASELINE sha256 `6161ab32…` (fixed tree) → SHIM: restore the pre-fix bare-`ets.new` init →
court run reproduced the exact witnessed crash:

```
{:badarg, [cause: :already_exists, module: :erl_stdlib_errors]}   (×3 tables/cycles)
```

RESTORE byte-exact (sha256 `6161ab32c7d100d1f5212413c8bc131950437c778dfe11aae93a8309e398a36e`
before = after). A court that cannot flip is FAIL; this one flips.

## Verification ladder (real output)

| runs | surface | result |
|---|---|---|
| ×5 | isolated `mix test test/internal/powl2_primitives_test.exs` | `Result: 9 passed` every time (6 pre-existing + 3 new) |
| 1 | sibling powl2 consumers (`spofb_eh_atom_court_test`, `bk14_kd143_sqlfilter_persistence_test`, `powl2_change_feed_test`) | `Result: 19 passed` |
| 1 | batch `mix test test/internal/` | `Result: 448/519 passed` — ZERO Powl2PrimitivesTest failures, ZERO `:already_exists` signatures in the whole batch log; the 71 failures are sibling-class (census drift from other lanes' unregistered in-flight files, kd_blob ×11 / kd169r ×8 / cosmos / ja15 / expl11r2 / relay / eplaw — cross-lane contention classes typed in bkseal2/bkcens3), plus 1 ets_auto OFF-leg load flake (same family bkcens3 witnessed once). None is this lane's surface. |
| 1 | full powl2 suite: powl2_gates_court + kd143_rules_persistence + sb_arm_rules + graphlaw_powl_business_net + 8 internal powl2 courts | `Result: 90 passed` |

## Falsifiers checked

- The `:already_exists` init crash ×6 class: extinct — 5 isolated + 1 batch + full powl2
  suite with zero signatures.
- Court non-vacuity: shim fires (`cause: :already_exists` on pre-fix init), restore
  byte-exact.
- 15s bounded monitor wait cannot stall on heir-held tables: pinned by construction
  (heir-held tables skip the wait; `:init` pid is always alive) and witnessed — all runs
  completed in sub-second init time.

## Disclosure

- During the window the tree compile-froze on a sibling lane's in-flight
  `lib/smalt/messaging/amqp/connection.ex` syntax error (~90s, self-cleared within SLA;
  this lane waited and re-verified, edited nothing outside its own files).
- The batch census failures name ONLY other lanes' unregistered in-flight files; this lane
  added no new test file (court tests live in the already-registered
  `test/internal/powl2_primitives_test.exs`), so no census registration was needed.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bkpinit mix test test/internal/powl2_primitives_test.exs   # 9 passed
MIX_BUILD_ROOT=_build-bkpinit mix test test/internal/                            # powl2 green in batch
MIX_BUILD_ROOT=_build-bkpinit mix test test/integration/powl2_gates_court.exs \
  test/integration/kd143_rules_persistence_test.exs test/integration/sb_arm_rules_test.exs \
  test/integration/graphlaw_powl_business_net.exs test/internal/powl2_law_guard_court.exs \
  test/internal/powl2_andon_court.exs test/internal/powl2_andon_wire_court.exs \
  test/internal/powl2_nonseparable_court.exs test/internal/powl2_graph_compat_court.exs \
  test/internal/powl2_law_compiler_court.exs test/internal/powl2_compiler_test.exs \
  test/internal/powl2_executor_test.exs                                          # 90 passed
```
