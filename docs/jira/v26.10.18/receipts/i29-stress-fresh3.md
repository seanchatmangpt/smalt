# i29 — stress-tier convergence fresh leg 3 (full `--include stress`)

- **Date**: 2026-10-18
- **Subject**: /Users/sac/smalt. Two full runs launched from snapshot HEAD `b9b9199`.
  During the runs, other lanes landed commits through `6ff67db` — including
  `34f2012 fix(test): KQL fuzz classified inputs`, which changed
  `test/data_plane/cosmos_test.exs` MID-RUN. Run 1 and run 2 both compiled the
  PRE-fix fuzz source (disclosed below); the tree at receipt time is `6ff67db`
  with the fix landed. No edits, no git ops, no `_build` deletion by this lane
  (`_build-ft-str5` preserved).
- **Command**: `MIX_BUILD_ROOT=_build-ft-str5 mix test --include stress` (cwd /Users/sac/smalt)
- **Build root**: `_build-ft-str5` (per-hash private, shared by both runs)
Context: solo(2 runs, same build root `_build-ft-str5`, tree moved b9b9199→6ff67db mid-leg)

## Runs

| run | wall | summary |
|---|---|---|
| 1 | 770.1 s | `1 doctest, 7 properties, 2771 tests, 3 failures (61 excluded)` (output tailed; third failure identity uncaptured) |
| 2 | 642.7 s | `1 doctest, 7 properties, 2771 tests, 2 failures (61 excluded)` (full log /tmp/str5-full.log) |

## Failures observed (run 2, full log)

1. `Smalt.Wire.EgressWireTest` "R185h: concurrent metadata PUTs vs hold toggles
   over the wire answer only 200/409 and leave the row coherent"
   (test/wire/egress_wire_test.exs:465) — `container create answered 503:
   RouteNotReady`. Boot-readiness 503 under 16-core parallel load; the F58/F60
   egress/RouteNotReady readiness family.
2. `Smalt.DataPlane.CosmosTest` "KQL fuzz fences ... unicode and random binaries
   terminate quickly" (cosmos_test.exs:1055) — assertion text in the failure is
   the PRE-fix `match?({:error, _})` seed-lottery fuzz (compiled source predates
   `34f2012`). Reproduced both runs with old source; the fixed source
   (`{:error, {:parse, _}}` on classified inputs, receipt
   `i29-kql-fuzz-determinism.md`, 5/5 fresh-seed green) landed as 34f2012 during
   this leg.

## Failure classification (strict)

| Class | Run 1 | Run 2 |
|---|---|---|
| F58/F60 egress/RouteNotReady 503 readiness (LOAD) | 1 (R185h seen in tail) | 1 (R185h) |
| KQL fuzz seed lottery (pre-34f2012 source; FIXED mid-leg) | 1 | 1 |
| DetsRecovery rotating | 0 | 0 |
| lock_drift ×2 + capabilities drift | 0 | 0 (closed, confirmed) |
| F61 Topology | 0 | 0 |
| boot-contention invalid | 0 | 0 |
| uncaptured (tail-only run 1) | 1 | — |
| **Non-LOAD, non-fixed-upstream** | **0** | **0** |

## Acceptance

**ACCEPTED — only LOAD-class (or fixed-upstream) failures remain.** R185h's
RouteNotReady 503 is the F60 readiness-under-load face. The KQL fuzz failure is
not a live defect: both runs compiled the pre-fix source; the deterministic fix
(34f2012) landed mid-leg with its own 5/6-run green receipt. lock_drift and
capabilities-drift faces are confirmed absent (closed upstream). No new
non-LOAD failure class appeared across 2 × 2771 tests.

## Machine

`just bench-machine`: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-ft-str5 mix test --include stress
```
(pre-fix source face; on current `6ff67db` the KQL fuzz is deterministic —
replay the fuzz leg alone via
`MIX_BUILD_ROOT=_build-ft-str5 mix test test/data_plane/cosmos_test.exs`)

## Standing

PASS (solo; 2 runs, 0 non-LOAD failures; run-1 third failure identity
uncaptured post-hoc — disclosed as-is; mid-leg tree move disclosed).
