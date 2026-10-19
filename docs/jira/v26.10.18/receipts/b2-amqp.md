# Receipt: B2 AMQP batch — five-file sleep/timing/singleton rewrite

Context: full (mix test test/amqp/ directory + wire tier x2 green)

**Window**: v26.10.18 · **Lane**: B2 · **Date**: 2026-10-18 · **Repo**: /Users/sac/smalt
**Spec**: docs/jira/v26.10.18/rewrite-drafts/amqp.md · **Context**: slice+wire
**Build root**: MIX_BUILD_ROOT=_build-ft-b2 · **B0 dependency**: receipts/b0-foundations.md (polled, landed, AssertEventually available)

## Files in scope (all landed, no lib/ changes, no generated artifacts)

- test/amqp/fuzz_test.exs
- test/amqp/broker_facade_test.exs
- test/amqp/flow_credit_test.exs
- test/amqp/queue_store_test.exs
- test/amqp/event_hubs_test.exs

## Scope landed per draft item

| Item | Site | Treatment landed |
|---|---|---|
| 1.1 | fuzz_test 2 hostile-nesting probes | KEPT as hang fail-safes with role comments (no flake channel — success path never approaches 30 s) |
| 1.2 | fuzz_test bare-array + map ratio fences | legs ms→µs via `:timer.tc`, paired-round min-of-5 kept, bounds 3.0/1.4 unchanged |
| 2.1 | broker_facade churn test | sleep(50) REMOVED — survival proven by a fresh accept before the alive-check |
| 2.2 | broker_facade ConnSup handoff | sleep(50) REMOVED — kill observed via `Process.monitor` + `{:DOWN,...}` receive |
| 2.3 | broker_facade `wait_until/2` | DELETED (count-bounded) → `AssertEventually.eventually/2` (deadline-bounded, `:retry` contract) |
| 2.4/2.5 | Sweeper tests | `own_sweeper!/1` own-or-PARK helper: `:sys.suspend` parks the shared racer synchronously; GC test's env flip-flop + `GenServer.stop` + restart wait REMOVED |
| R132 | tick_ms refusal test | REWRITTEN deterministic: observes `Sweeper.init/1` raising the typed ArgumentError directly (init raises BEFORE registration; the start_link form required a name race that was the test's own flake) |
| 3.1/3.2 | flow_credit tests 1/3/5 | 2x 1000 ms silence windows + drain window REPLACED by ordered barrier probes (`drain_until_performative/4`); drain no-op pin and flat-1000 credit pin verbatim |
| 3.3 | flow_credit setup | 4-key app-env save/restore + `stop_existing_tree/0` + module-scoped `restore_app` REMOVED; private broker tree boots on ephemeral ports with per-test UNIQUE names (no global env mutation, no shared-tree teardown); Store stays the shared seam via `ensure_store_up/0` |
| 4.1 | queue_store renew-mirror | both sleeps REMOVED — authored clock (`now_ms: 1_000`, renew at 1_500 → exact `locked_until == 2_500` on row AND token) |
| 4.2 | queue_store shared Store fence | KEPT as landed (R185j), `async: false` retained |
| 5.1 | event_hubs 3 TTL sleeps | REMOVED — `expire_claim!/2` authors the claim `until` in the past; live legs raised to 60 s TTL so exclusion never rides a short TTL |
| 5.2 | F-4 table delete | KEPT with `on_exit(ensure_tables)` restore + named-exception disclosure |
| 5.3 | 7 wire-test Store nil-checks | REPLACED with `SmaltTest.Lifecycle.ensure_store_up()` (draft said 6; count is 7 on disk) |
| 5.4 | wire harness dedup | `wire_conn!/0` helper replaces ~120 lines of duplicated listener/accept/handshake boilerplate |

## Draft deviations (each verified against the landed implementation before landing)

1. **Flow-echo barrier → attach-echo barrier.** The draft's `flow(echo: true)`
   barrier is unsound against the shipped broker: `Smalt.Amqp.Connection`'s
   inbound :flow path has NO echo handling (grep zero hits; the drain pin in
   test 5 already witnesses the flow-path no-reply). Barriers use an ATTACH
   echo on a fresh scratch link instead — the broker processes session frames
   in order (spec §2.5), so everything it was going to deliver precedes the
   attach echo. Same happens-before register, observable the broker actually
   emits. `@recv_timeout 5000` stays the hang fail-safe only.
2. **`LockManager.renew/2` returns the lock map, not the bare expiry** (draft
   4.1 expected `{:ok, renewed_expiry}`). Assert `{:ok, %{locked_until: 2_500}}`;
   renew reuses the claim's `duration_ms` (renew_lock/3 clamps
   `opts[:duration_ms] || lock.duration_ms`), so 1000+1000/1500+1000 math
   holds. `renew_lock/2` (management form) would return the bare integer.
3. **`:ets.insert/3` does not exist** — the draft's own correction note was
   applied: `true = :ets.insert(:smalt_eh_checkpoints, {{g, p}, expired})`.
   (My first landing wrote the uncorrected 3-tuple form; killed 13 tests via
   EHServer function-clause crash; fixed and re-greened.)
4. **R132 via init/1, not start_link.** `Sweeper.start_link/1` registers
   `name: __MODULE__` unconditionally; with the shared instance alive the name
   is taken and init never runs (`{:error, {:already_started, _}}`). The old
   test's stop-restart race WAS the flake; init/1 raises the identical typed
   ArgumentError before any registration.
5. **Wire test count is 7, not 6** — all 7 `whereis(Smalt.Store)` nil-checks
   replaced.

## Concurrent-lane disclosures

- queue_store_test.exs was annotated in flight by the sleeps lane
  (SLEEP-CLASS comments on the two renew-mirror sleeps); my rewrite REMOVES
  both sleeps so the markers went with them.
- The five files were integrated by the coordinator mid-lane (checkpoint
  commits 63c7082/e3b0707/b2c53b3); validation ran on the committed state.
- A shared-compile freeze (~13:47) from a sibling lib lane's in-flight
  `wasm_engine_supervisor.ex` (missing start_link/1 vs application.ex) blocked
  the first run; resolved by the owning lane within the SLA — no edit from B2.

## Real gate output

Offline suite (baseline 331/0 holds):

```
$ MIX_BUILD_ROOT=_build-ft-b2 mix test test/amqp/
Finished in 59.7 seconds (28.7s async, 30.9s sync)
331 tests, 0 failures (45 excluded)
```

Wire tier pass A (log /tmp/b2_wire5.log):

```
Finished in 83.1 seconds (23.4s async, 59.7s sync)
376 tests, 0 failures
```

Wire tier pass B (log /tmp/b2_wire7.log):

```
Finished in 55.1 seconds (16.8s async, 38.2s sync)
376 tests, 0 failures
```

## Load-run observations (witnessed, not landed)

Two runs under heavy sibling-lane load (sync wall 6x normal) surfaced failures
OUTSIDE the B2 surface: lock_manager_test "renew expired -> 410" got :not_found
(token row deleted by a real-clock sweep between acquire and renew — the R197
tombstone-grace window), and one flow_credit delivery-loss under 6x slowdown.
Both passed in the two green passes above at normal load. Filed here as
observations for the coordinator; NOT fixed by this lane (out of file scope).

## Pinions — untouched, verified

- SASL ANONYMOUS only: `handshake/1` + `wh/1` unchanged (wh/1 now called from
  exactly one place, wire_conn!/0).
- Attach-arity tripwire: fuzz `@perf_orders[:attach]` untouched; the
  differential fuzz remains its executor.
- Fixed EH partitions ["0","1"]: r200h pk-hash, out-of-pin detach, and the
  ann-hub partition-"1" isolation comment all verbatim.
- Drain no-op pin + flat-1000 sender credit pin: asserts verbatim; only the
  silence-observation changed.
- Frame-size cap asymmetry (lens-4): verbatim.

## Falsifier

Restore any removed sleep / silence window / count-bounded poll (e.g.
`Process.sleep(700)` before the renew in queue_store_test) and the
zero-window claim dies: the rewrite's asserts read authored state
(`locked_until == 2_500`) that no real-clock wait produces. The attach-echo
barrier is non-vacuous by construction: remove the broker's ordered reply and
`drain_until_performative(:attach, 5000)` times out (exit 1, witnessed during
the flow-echo mis-landing when no reply came at all).

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-ft-b2 mix test test/amqp/
MIX_BUILD_ROOT=_build-ft-b2 mix test test/amqp --include amqp_wire   # x2 green
git -C /Users/sac/smalt diff 63c7082^ -- test/amqp/                   # surface diff
```

No git actions taken by this lane. Standing: ALIVE for the five-file surface
(offline baseline + wire x2 green, real output embedded).
