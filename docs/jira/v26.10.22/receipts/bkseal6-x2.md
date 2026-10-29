# BK-SEAL6 — seal ×2 post-quiet leg (successor to BK-SEAL5)

- **Date**: 2026-10-22
- **Lane**: BK-SEAL6
- **Context**: solo (fan-out draining; other lanes landing through the window)
- **Standing**: **PARTIAL_ALIVE** — the v26.10.22 seal ×2 close condition is
  **NOT MET** on this run. The post-quiet full suite does not return an
  exit-0-class line; a real, root-caused suite-stability defect (ETS-AUTO
  supervisor-intensity give-up) blocks it. Both this run's repairs and the
  blocking defect are typed below.

## Step 1 — wait-bounded quiet window (expired, typed honestly)

Polled `just quiet-check` every ~2 min, 07:28–07:57 (12 polls). Load fell
121 → 15/20 over the window but quiet-check never passed. Persistent typed
violations at expiry:

```
- stray beam pid 1788 .../.erlmcp/otp-28.3.1/.../beam.smp (foreign beam, not this checkout)
- court ports 9443/8443/5672/5673/9444 occupied (substrate UP, pid 68017 — verified later via just substrate-status)
- load 15.1/20.4 > threshold (16 cpus)
```

Proceeded per the BK-SEAL3/BK-SEAL5 precedent with typed load annotation.
Calm-machine class: load 6–21 for all runs below.

## Step 2 — full mix test (4 attempts, the honest sequence)

| # | time | result line | verdict |
|---|---|---|---|
| 1 | 08:02 | `Result: 702/877 passed, 11 invalid; Failed: 175` | mass failure |
| 2 | 08:11 | `Result: 876/888 passed; Failed: 12` | near-clean |
| 3 | 08:28 | `Result: 729/883 passed, 5 invalid; Failed: 154` | mass failure |
| 4 | 08:39 | `Result: 884/888 passed; Failed: 4` | residual |

Attempt 1 was also poisoned by mid-window coordinator commits (population
drift 872→877→883→888 across runs; `5 invalid` = files changed mid-run).

### Census SLA unblocks (disclosed, same class as BK-SEAL5's store4)

BK-B4RC landed `b4rc_send_gate_court_test.exs` unregistered. Applied the
minimal compile-freeze-SLA unblock in
`test/internal/internal_tier_census_test.exs`: (a) registered
`b4rc_send_gate_court_test.exs => :internal`; (b) added `:status_literal`
exemption (the court asserts raw `{status, ct, body}` tuples — status
literals are the subject under test); (c) added `Smalt.Amqp.AtomBridge` to
the observables allowlist (the management-plane dispatcher the b4 harness PUT
lands on); (d) split the b4rc file's `alias Smalt.Amqp.{AtomBridge,
QueueStore}` into two explicit aliases so the census regex sees full module
names. Census rerun: `Result: 6 passed`. **These edits were swept into a
coordinator tick commit mid-window** (tree clean again at receipt time) —
disclosed for both lanes' receipts.

### Defect 1 (FOUND + FIXED): Ja15 hostile-formatter capture_log smear

The Ja15 court installed an **always-crash formatter on the shared
`:default` logger handler**. Any concurrently running async test whose
ExUnit `capture_log` window opens mid-hostile captures the hostile config as
its "original" and reinstalls it after this court restores correctly — the
BK-70 fix (capture-before-overwrite) closes the self-restore hole, not the
cross-module race. Witnessed in attempt 3's log: `FORMATTER CRASH ...
ja15 hostile formatter always crashes` re-formatting unrelated boot events at
08:33, minutes after the court ran; 154 failures dominated by
`econnrefused`/RouteNotReady smear. Fix (test-only, intent-preserving):
`Smalt.Ja15.HostileFormatter.format/2` now crashes ONLY on the court's own
probe events ("ja15 hostile probe 1") and delegates everything else to
`:logger_formatter.format/2` — the default handler still observes a real
formatter crash on the probe (non-vacuity kept), and any leaked window is
harmless to unrelated tests. Court file-alone: `Result: 10 passed`.
Effect: full-suite failures 154 → 4.

### Defect 2 (FOUND, ROOT-CAUSED, NOT FIXED — owning surface ETS-AUTO/BK-CENS3): supervisor-intensity give-up

`test/internal/ets_auto_court_test.exs` recreates `:smalt_rolling_counters`
by `GenServer.stop`-ing the supervised `Smalt.Telemetry.RollingCounters` —
2 leg recreates + 2 in the 64-task court = 4 stop/restart cycles per file
run. `Smalt.Telemetry.RollingCounters` is a direct child of the top-level
`Smalt.Supervisor` (`lib/smalt/application.ex:26`) with DEFAULT restart
intensity (1 restart / 5 s). Probe receipt (mix run, 6 stops 300 ms apart):

```
1: old=#PID<0.2600.0> new=#PID<0.2907.0> sup_alive=true
2: old=#PID<0.2907.0> new=#PID<0.2908.0> sup_alive=true
3: old=#PID≥0.2908.0> new=#PID<0.2909.0> sup_alive=true
4: old=#PID<0.2909.0> new=nil sup_alive=false   <- Smalt.Supervisor GIVES UP, app dies
```

(The #3 line is typo'd `#PID≥` from the probe transcript; substance
unchanged.)

The court's 4-cycle cadence deterministically trips intensity →
Smalt.Supervisor gives up → the whole app dies mid-suite. BK-CENS3's round
deletion (ERRRC) removed the >5 s natural spacing the deleted rounds
provided — the deletion unmasked the intensity cliff. Evidence:
ets_auto ON-leg/64-task failed in EVERY full run and file-alone
(2/3, `RollingCounters restart did not converge:
{:error, {:restarting, nil, ...}}`); in the court run its early seed position
produced the ~40-test transport smear (`Result: 846/888 passed; Failed: 42`,
court `test-offline` exit 2). Single stop/restart is healthy (probe cycles
1–3 green). **Not fixed by this lane**: the repair belongs to the
ETS-AUTO/BK-CENS3 surface — options named for the owner: give
RollingCounters its own intermediate supervisor (intensity absorbed off the
top-level), or restructure the court to ≤2 stop/restart cycles per run with
real spacing. Falsifier for the repair: a full suite where the ETS-AUTO file
runs EARLY in the seed and the run still returns a clean line.

### Residual 4 (attempt 4)

| # | test | class |
|---|---|---|
| 1 | ets_auto ON leg | Defect 2 (above) — real, not contention |
| 2–3 | vm_zero_growth conn-sup churn + lazy singleton | BK-SEAL5 contention-flake class (census-delta, non-deterministic set) |
| 4 | spof3 SPOF-3.2 busy observation | unclassified; failed attempts 2/4 + isolation; busy-observation race, no lib/ defect implicated |

## Step 3 — `just court` composite

Ran to the first failing stage:

```
Result: 846/888 passed
Failed: 42 tests
error: recipe `test-offline` failed on line 85 with exit code 2
```

Failure distribution is Defect 2's blast radius (ets_auto seeded early →
~40 downstream transport smear + 2 direct). The composite could not reach
the later stages; typed INCOMPLETE, blocked on Defect 2.

## Verdict

- **Seal ×2: NOT MET.** BK-SEAL5's ALIVE was real for its run; the
  post-quiet rerun surfaced two real suite-stability defects that
  load-classification had masked.
- Defect 1 is repaired on this tree (landed via coordinator tick commit;
  witnessed 154→4). Defect 2 is root-caused with a probe receipt and owned
  by the ETS-AUTO/BK-CENS3 surface; until it lands, the full suite is
  seed-order roulette (early ets_auto ⇒ ~40-test smear; late ⇒ 4-failure
  residual), so no clean x2 line is claimable.
- After Defect 2's repair, the expected x2 leg is a single full `mix test`
  with 0-failure-class line + `just court` reaching the census stages.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bkseal6 mix test test/internal/internal_tier_census_test.exs   # 6 passed
MIX_BUILD_ROOT=_build-bkseal6 mix test test/internal/ja15_error_logger_court_test.exs # 10 passed
MIX_BUILD_ROOT=_build-bkseal6 mix test                                                # attempt 4: 884/888
# probe:
MIX_BUILD_ROOT=_build-bkseal6 mix run -e '...6x {GenServer.stop(RollingCounters); sleep 300; whereis}...'
just court                                                                            # 846/888, exit 2 (Defect 2)
```

Full logs: `/tmp/bkseal6-mixtest-attempt{2,3,4}.log`, `/tmp/bkseal6-court.log`,
`/tmp/bkseal6-etsauto.log`, `/tmp/bkseal6-isolation.log`.
