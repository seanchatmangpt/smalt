# BK-33 — warm-restart rebind defect RESOLVED (root cause: heir-to-init ETS table survives System.restart)

Context: solo

- **Lane**: BK-33 (typed defect repair, two prior witnesses)
- **Date**: 2026-10-21
**Standing**: **RESOLVED / ALIVE** — warm `System.restart` now rebinds all 6
  listeners 3/3 under court; the hang + `rebind_ok=0` is gone. Root cause was
  NOT a port/reuseaddr/shutdown-order issue: it was an unguarded
  `:ets.new(:smalt_monitor_metrics, ...)` in `Smalt.Monitor.Metrics.init/1`.
- **Fix (one hunk)**: `lib/smalt/monitor/metrics.ex` `init/1` — delete the
  stale heir-surviving table before re-creating:
  `case :ets.info(@table) do :undefined -> :ok; _ -> :ets.delete(@table) end`.
  Note: the edit was carried into a coordinator tick-snapshot commit
  (744adcc "in-flight lane snapshots ... BK-33/..."), so it is already on
  `main` — this lane authored it; the coordinator owns the commits.
- **Result file**: `/Users/sac/smalt/tmp/bench/bk33-warm-restart.jsonl` (5 rows)
- **Harness**: `/Users/sac/smalt/tmp/bench/bk33_warm_court.sh` (bounded lsof
  polls, zero fixed sleeps; stop via `bin/smalt stop`; port block
  39950..39955, free at dispatch, zero residue post-run: 0 listeners,
  0 rel/smalt beams).

## Reproduction (pre-fix)

`tmp/bench/bk33_warm_reprobe.sh r1` — cold boot 6/6 listeners, then
`bin/smalt restart` (RPC `System.restart()`): `rebind_ok=0` over a 60 s
bounded poll; node log ends with the VM halting on
`application_start_failure: smalt — failed to start child
Smalt.Monitor.Metrics: table name already exists`
(ArgumentError at `lib/smalt/monitor/metrics.ex:303` `:ets.new`).

## Root cause (mechanism, witnessed in the node log)

`System.restart/0` kills every process EXCEPT `init`. Every
`{:heir, Process.whereis(:init), []}` ETS table therefore transfers to init
(the `init got unexpected: {:ETS-TRANSFER, :smalt_monitor_metrics, ...}`
lines) and **survives the restart**. All heir'd lazy tables (apim rate,
policy, app_insights, metric_alerts) are `:ets.info`-guarded for this; the
one unguarded site was `Metrics.init/1`, so the restarted app crashed on
boot, `application_controller` terminated the kernel, and the VM halted —
zero listeners rebound, appearing outwardly as a rebind/hang defect.

## Post-fix court (real output)

```
$ bash tmp/bench/bk33_warm_court.sh        # exit 0
cold boot listeners=6 wall=50164ms rc=0
warm-restart-1 rc=0 wall=25954ms listeners=6 rebind_ok=1
warm-restart-2 rc=0 wall=27100ms listeners=6 rebind_ok=1
warm-restart-3 rc=0 wall=23523ms walls are load-bound (concurrent lane load; quiet baseline 2.7-3.6 s)
warm-restart-3 rc=0 wall=23523ms listeners=6 rebind_ok=1
health=200 cosmos=200
COURT_FAIL=0
```

- Warm `System.restart` ×3: **3/3 rebind all 6 listeners** (rebind_ok=1,
  errors=0). One cold boot post-fix: unaffected (6/6 listeners; wall is
  load-bound — quiet baseline 1.9 s from t47/ttv6 stands).
- Post-restart serve: ARM `/subscriptions` 200, Cosmos `/dbs` 200.
- Post-run residue: 0 listeners on 39950..39955, 0 rel/smalt beams.
- Release rebuilt post-fix: `MIX_ENV=prod mix release smalt --overwrite`
  exit 0 (log `tmp/bench/bk33_build.log`).

## Regression check

`mix test test/integration/ja10_transparency_court.exs` (the suite that
exercises the supervised tree incl. `Smalt.Monitor.Metrics`): **5/5 passed**
post-fix (`MIX_BUILD_ROOT=_build-ft-bk33 MIX_ENV=test`). First run on the
same tree returned 4/5 with 1 failure under heavy concurrent lane load
(load-bound flake, disclosed; the clean rerun passed). Note: the rerun was
briefly blocked by concurrent-lane compile freezes (`sync/frame.ex`,
`store.ex`, `egress/SyncRoutes.ex` mid-edit — none touched by this lane;
polled green per the compile-freeze SLA).

## Typed residual (scoped, not part of this fix)

Any heir-to-init table created LAZILY after boot by an unguarded site would
have the same restart-crash class. Current census: all other heir'd sites
(apim.ex, policy.ex, app_insights.ex, metric_alerts.ex) are info-guarded,
so the class is closed on today's tree; new heir'd sites must carry the
guard (candidate for a sleep-gate-style mechanical gate later).

## Commands (exit codes)

```
bash tmp/bench/bk33_warm_reprobe.sh r1   # exit 1 = reproduced (rebind_ok=0, VM halt)
MIX_ENV=prod mix release smalt --overwrite  # exit 0
bash tmp/bench/bk33_warm_court.sh        # exit 0 (court green)
post-run: lsof 0 listeners, pgrep 0 rel/smalt beams
```
