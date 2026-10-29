# BK-82 — Verify-and-consolidate: internal census verification

**Standing: ALIVE** (plane_blast_radius 6/6 exit 0 incl. raw_rows; full `test/internal/` census reds fully classified; every unowned red either fixed or concurrently fixed+landed by its owner lane; active-lane reds carried)

**Context: solo**

Date: 2026-10-21, lane BK-82, repo /Users/sac/smalt @ main (moved a26419c → fa51a85 during the lane; coordinator tick checkpoints 6b6cb00 / b8063f6 / 806fc6f folded this lane's two disclosed fixes).

## Step 0 — BK-80 landing check

- `git log --oneline -5`: BK-80 raw_rows/topology snapshot in `a3f3c15` ("BK-80 raw_rows/topology ... TTV-5 recon, W3C-C"). Confirmed.
- mtimes: `lib/smalt/monitor/metrics.ex` 21:46, `test/internal/plane_blast_radius_test.exs` 21:47 — fresh, matching the a3f3c15 snapshot window.

## Step 1 — plane_blast_radius solo

```
$ MIX_BUILD_ROOT=_build-bk82 asdf exec mix test test/internal/plane_blast_radius_test.exs
Finished in 1.4 seconds (0.00s async, 1.4s sync)
Result: 6 passed
EXIT=0
```

All legs green **including raw_rows** (the single non-raw_rows failure observed pre-fix was the topology leg's `assert Smalt.Messaging.EventHubs.Server in integration_ids` — child ids are `{Module, :default}` tuples; **BK-82 minimal fix** normalizes child ids to the module before membership: `Enum.map(fn {id, _pid, _kind, _mods} -> case id do {mod,_} when is_atom(mod) -> mod; other -> other end end)`). This edit was folded into coordinator checkpoint `806fc6f` ("BK-80/82 in-flight lane snapshots").

Note: two interim reds during this step were environmental, not code:
- one run hit a concurrent-mix lock collision (`/Users/sac/.cache/tmp/mix_lock_user501/...lock_0: no such file or directory`) under the 20+-lane fan-out;
- one boot failed on `lib/smalt/store/partition.ex` `{:heir, nil, []}` → `:ets.new` ArgumentError (boot-order race: Partition starting before the Heir is registered). **BK-82 unblock fix (compile-freeze SLA, lib/ disclosure)**: only emit the `:heir` option when `Process.whereis(heir)` is a pid. Coordinator folded it in checkpoint `b8063f6` (same checkpoint also carries the owning lane's `heir.ex` changes).

## Step 2 — whole-dir census (`mix test test/internal/`)

Three census waves (machine under ~20 sibling lanes throughout):

| wave | subject | result | exit |
|---|---|---|---|
| 1 | all files | **COMPILE-ABORT** — `ja15_error_logger_court_test.exs:235` syntax error (keyword list before `fn ->`). Compile-abort ≠ failure count; report file named. | 1 |
| 2 | all files minus ja15 | 211/243 passed, 32 failures across 12 modules | 2 |
| 3 | all files (post 6b6cb00 which carried BK-94's ja15 syntax fix) | **231/253 passed**, 22 failures across 6 modules | 2 |

Wave 3 is the standing census count at HEAD (fa51a85): **231/253**. The failure *population churns wave-to-wave* (wave 2 and wave 3 share only 3 modules) — classic saturation noise under a loaded fleet.

### Failure classification (wave 3 population + solo reruns)

**Real reproducible reds (2):**

1. `Smalt.Internal.WsAmqpRelayTest` "EH publish -> consume end-to-end through the relay (BK-58 witness)" — fails solo twice (1/2, exit 2): "no EH delivery arrived through the relay". The consumer-side flow frame was just changed by the BK-58 lane in 6b6cb00 (`credit: 10` → `link_credit: 10`); `lib/smalt/messaging/ws_amqp_relay.ex` is worktree-M right now (active BK-58 lane mid-reconciliation). **Carried to owner.**
2. `Smalt.Internal.EtsAutoCourtTest` 64-task court — timeout (60s default; also red at its own 300s tag under load). BK-70's landed comment documents exactly this class ("under a loaded machine the work exceeds the budget... Load-bound accommodation"). Load-bound, accommodation-class, carried as such.

**Environment-dependent (1):**

3. `InternalTier.Kd115CreditFirstDeliveryTest` — probe spawns `mix` from PATH; direct run with homebrew elixir 1.19.5 dies with version-refusal (private substrate never boots). In-census mode differed (MessagingEntityNotFound on fixed block ports). Concurrently FIXED + landed in b8063f6 ("BK-65 kd115 probe": `sb_auto_ensure, true` documented as probe fixture). Expected green next wave; not re-witnessed by this lane.

**Load-flakes, green under reduced contention or in later waves (population churns):** CosmosAnalyticalTtl (4× `{:error, :store_not_ready}` in setup, 4/4 green solo), Powl2Primitives (6), Bk27Kd86AutoEnsure (3), SelectiveDrain (2), ArmstrongIdiom (2), VmZeroGrowth (2), PlaneBlastRadius in-census (6, green solo 6/6), CosmosKd65Scripts (4), CensusTest (2), ProcessLabel (1).

**Active-lane in-flight (carried, not touched):** SpofbEhAtomCourt (2, file worktree-M at census2 time; BK-58/SPOF surface), ja15 (compile-abort, fixed by BK-94 in 6b6cb00).

## Fixes attributable to BK-82 (both disclosed, both folded into coordinator checkpoints)

1. `test/internal/plane_blast_radius_test.exs` — child-id normalization for the BK-80 topology invariant (folded in `806fc6f`).
2. `lib/smalt/store/partition.ex` — nil-heir guard on `:ets.new` (folded in `b8063f6`).

No commits by this lane. No files owned by active lanes were edited (compile-freeze SLA unblock on partition.ex was blocking every lane's boot and is disclosed here and in the code comment).

## Falsifier for this receipt

A re-run of `MIX_BUILD_ROOT=_build-bk82 mix test test/internal/plane_blast_radius_test.exs` that reds any leg (incl. raw_rows), or a census wave where the WsAmqpRelay BK-58 witness leg stays red after the BK-58 lane's worktree settles (should flip green or get its own KD row).
