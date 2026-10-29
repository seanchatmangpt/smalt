# BK-45: RollingCounters heir parity + DetsMirror EXIT/catch-all clauses + kill court

**Standing: ALIVE** (for the three BK-45 changes; verified on the exact subject described
below). `Context: solo`

## Diff summary

All three diffs were swept into coordinator tick checkpoint `d6ccf5c` ("TTV-5 ALIVE —
heir-to-init adoption, 3-leg kill court"); working tree is clean for these paths.

1. `lib/smalt/telemetry.ex` — `RollingCounters.init/1` now mirrors the `Monitor.Metrics`
   idiom (`lib/smalt/monitor/metrics.ex` init/1): stale-table delete before
   `:ets.new` (the BK-33 warm-restart rebind defect class), then the 3-tuple
   `{:heir, Process.whereis(:init), []}` option. A RollingCounters death no longer
   deletes `:smalt_rolling_counters` mid-prune-gap (JA-6 / BK-28 re-witness). The
   init/recreate fallback (persistent_term boot marker, bump/1 log-and-drop, table_rows/0
   log-and-empty) is unchanged.
2. `lib/smalt/store/dets_mirror.ex` — added the JA-11 systemic trap_exit risk-class
   clauses after `handle_info(:tick, ...)`: `handle_info({:EXIT, _from, reason}, state)`
   (log + `{:noreply, state}`, wasm/pool.ex idiom) and a final
   `handle_info(unexpected, state)` catch-all with `Logger.warning` naming the message.
   `handle_info(:tick, ...)` untouched.
3. `test/internal/plane_blast_radius_test.exs` — new real-kill court "heir parity:
   killing RollingCounters and Monitor.Metrics leaves their ETS tables alive and cleanly
   re-adopted after supervisor restart": seeds a real counter + a real
   `[:smalt, :egress, :refused]` telemetry sample, `Process.exit(pid, :kill)` both
   GenServers, bounded polls (`SmaltTest.Internal.Poll.eventually`) on
   `:ets.info/1`, fresh-pid re-registration under `Smalt.Supervisor`, and post-restart
   write-through (bump + telemetry → row present). No sleeps, no mocks. Closes the
   JA-6 gap "no kill test for RollingCounters/Monitor.Metrics".

## Court output

Machine under the concurrent wave (load avg 146; multiple other lanes' mid-write
breaks: SyncRoutes.ex, store.ex, data_supervisor.ex — all transient, none in BK-45
files). Two clean windows:

- Run A (21:15, window in bf2gwo1pl attempt 1, after the raw_rows fix):
  `Result: 5 passed`, exit 0.
- Run B (21:40, final, current tree incl. other lanes' later churn):
  `Result: 4/5 passed, Failed: 1` — the ONLY failure is the pre-existing
  "topology" test (`assert integration_ids == [Smalt.AmqpBroker]`), red because
  another lane added `{Smalt.Messaging.EhGeoDr, :default}` and
  `{Smalt.Messaging.EventHubs.Server, :default}` children to the integration
  supervisor in the same window. The BK-45 heir-parity court PASSED in Run B.
  Session-external failure, owner: the integration-plane lane.

New finding (pre-existing, NOT introduced by BK-45): `Smalt.Monitor.Metrics.raw_rows/0`
(lib/smalt/monitor/metrics.ex) destructures each ETS row as `{r, m, b}` (the key shape)
instead of `{{r, m, b}, c, s, mx}` — it raises "no function clause matching" on any
non-empty table. First witnessed by this court's seed poll; the court reads the real
table directly instead. Owner: metrics lane.

## Commands / exits

```
MIX_BUILD_ROOT=_build-bk45 mix compile                       # exit 0 (multiple reconfirmations)
MIX_BUILD_ROOT=_build-bk45 mix test test/internal/plane_blast_radius_test.exs
#   Run A exit 0 — "Result: 5 passed"
#   Run B exit 1 — "Result: 4/5 passed" (topology test, session-external; BK-45 test passed)
```

Elixir 1.20.4-otp-29 (asdf, resolved from .tool-versions; brew elixir 1.16/OTP28 refuses
`~> 1.20`).
