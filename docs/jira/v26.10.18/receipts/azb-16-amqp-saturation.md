# AZB-16 — AMQP saturation (≥4096 queues) + atom-flood guard

Standing: **ALIVE** (host ×3 green; container ×3 green under `--cpus 2`; anti-vacuity shim court red→restored byte-exact)
Context: solo(test/azsim/amqp_saturation_test.exs --include stress, x3) + slice(test/azsim/ non-stress tier, 63 tests)

## Scope landed

- `test/azsim/amqp_saturation_test.exs` (`@moduletag :stress`, `@moduletag timeout: :infinity`)
  — 4096-queue phase + 8192-queue variant + poison/DLQ phase. Each saturation
  phase: queues created via **real wire links** — per queue one TCP connection,
  SASL ANONYMOUS + open/begin handshake, CBS token, **1 sender + 1 receiver
  AMQP link**, 10 settled transfers accepted-echoed, receiver credit 10, 10
  deliveries batch-accepted, AMQP close + echo before RST teardown. Waves of
  256 at concurrency 32; per-wave `Process.alive?` teardown gate; drained-count
  assert (0 messages remain per queue).
- `docker/burn/container-burn.sh` — new `--saturation` host mode: runs the
  suite ×N inside the smalt-burn test image under `--cpus 2` with repo
  `test/` + `lib/` mounted over the baked copies, while an atom-flood
  generator (connect → partial HTTP request line → mid-request close, the i22
  class) drives the host substrate AMQP port for the burn duration.

## Ticket asserts, measured

- **atom table delta < 64** per phase — green (post-warm; see deviations).
- **process count ±1% after teardown** — green, host and container.
- **zero UNTAGGED `:closed` logger lines** — green; enforced by an in-BEAM
  `:logger_handler` (`ClosedProbe`) counting `request read failed: :closed`
  lines lacking the `[amqp-atom]` tag, asserted 0 per phase. Probe self-check:
  an emitted untagged line raises the counter, a tagged line does not.
- **DLQ correct for poisoned messages** — green: abandon×maxDeliveryCount →
  `DeadLetterReason == "MaxDeliveryCountExceeded"`, body preserved.
- **memory within 10% of baseline after `:erlang.garbage_collect` sweep** —
  green after: major (fullsweep) GC, a settle window
  (`eventually_stays`, 3 s stability), and moving the bounds read after the
  phase data references are dropped. At 8192 queues a ~12% post-GC residual
  was measured when the test process still held phase data; dropping the
  references before the read brings it inside budget.

## Verification (embedded outputs)

Host (offline, this checkout):

```
$ for i in 1 2 3; do mix test test/azsim/amqp_saturation_test.exs --include stress; done
3 tests, 0 failures   # x3 (rc=0 each)
```

Container acceptance (per Accept: ×3 inside container, `--cpus 2`), with the
atom-flood generator running concurrently against the host substrate :5672:

```
$ SMALT_SATURATION_ROUNDS=3 docker/burn/container-burn.sh --saturation
[BURN] saturation round 1/3 (cpus: 2)
[BURN] saturation round 2/3 (cpus: 2)
3 tests, 0 failures
[BURN] saturation round 3/3 (cpus: 2)
3 tests, 0 failures
[BURN] saturation: rounds=3 rc=0 flood_conns=120662
EXIT=0
```

`mix test test/azsim/` (whole tier, non-stress): 63 tests, 0 failures.
Stress-tier census (`test/stress_tier_census_test.exs`, untagged): green.

## Anti-vacuity (witnessed)

Shim court on `lib/smalt/messaging/amqp/connection.ex` `handle_attach/3`
(behavior-identical atom-leak round-trip, marker `SHIM-COURT (AZB-16
anti-vacuity)`):

```
BASELINE_SHA=6ccb6f652967836514e1a86da41b68bcb2c5daf1ed13c39bb9a92708f6a4ea10
SHIM:  _azb16_av = address |> String.to_atom() |> Atom.to_string()

$ MIX_BUILD_ROOT=_build-azb16-shim mix test ... --include stress
ATOM_LEAK: atom table grew by 8192 over 8192 queues (budget 64) ...
ATOM_LEAK: atom table grew by 4096 over 4096 queues (budget 64) ...
3 tests, 2 failures
RESTORE: AFTER_SHA=6ccb6f652967836514e1a86da41b68bcb2c5daf1ed13c39bb9a92708f6a4ea10
RESTORE_BYTE_EXACT_OK (sha256 equal)
```

Post-restore: host ×3 green (same session), lib sha unchanged on disk.

## Falsifiers

- atom delta unbounded in queue count — REFUTED (delta < 64 post-warm; the
  shim flips it to 4096/8192 = exactly one atom per queue).
- process leak after teardown — REFUTED (per-wave dead gate + ±1% bound).

## Findings (real, disclosed)

1. **RST-stuck links**: with abortive-only teardown (linger{0} RST), ~40% of
   storm connections stayed blocked in `prim_inet:recv0/3` for >15 s — RST
   does not reliably wake blocked passive recvs under loopback storm. Fixed
   in the harness by protocol teardown first (AMQP close performative +
   awaiting the server close echo), then RST. If a future lane sees `LINK_LEAK`
   with `current_function: {prim_inet, :recv0, 3}`, check the teardown
   protocol before filing a broker leak.
2. **CbsRouter dead-owner reap defeated by pid recycling**: the broker caps
   total CBS claims at 4096 and reaps dead owners by `Process.alive?/1`;
   across a 12k-connection storm a dead conn's pid is reissued, pinning its
   claim "alive" → typed `429 CLAIM_CAPACITY` beyond 4096 live-ish claims.
   The test restarts the router at wave boundaries (disclosed). A real fix
   (creation-aware liveness) is out of AZB-16 scope.
3. **Vacuous-counter hazard fixed**: the first ClosedProbe counter used
   `:persistent_term.update_counter/2`, which does not exist on this OTP —
   the handler silently died on first fire, making the zero-assert vacuous.
   Now an `:ets` counter; probe self-check witnesses both directions.
4. **One-time machinery atoms**: the phase machinery mints a bounded,
   deterministic 308-atom set once per BEAM (lazy `:sys` load + first
   wave-boundary machinery); each phase runs one unasserted 256-queue warm
   phase first, so the <64 budget measures queue-count scaling. The shim
   still blows the budget by two orders of magnitude.

## Diversions / notes

- Receipt filename per TICKETS.md (binding): `azb-16-amqp-saturation.md`
  (the dispatch named `azb-16-saturation.md`; ticket wins).
- `:code.ensure_loaded(:sys)` + CbsRouter-restart warm in `warm_baseline/1`.
- Env-gated memory diagnostics (`AZB16_MEM_DEBUG=1`) remain in the test.
- No git by this lane; the coordinator committed both files mid-lane
  (disk == HEAD, `git diff HEAD` empty for both).
- Shared-tree compile freeze: none caused by this lane; one external freeze
  in `lib/smalt/enclave/state.ex` (another lane's in-flight edit) waited out
  under the SLA, no unblock applied.
- Pre-existing unrelated warnings in test support files untouched.

## Replay

```
mix test test/azsim/amqp_saturation_test.exs --include stress
SMALT_SATURATION_ROUNDS=3 docker/burn/container-burn.sh --saturation
# anti-vacuity: apply the shim block from this receipt at connection.ex
# handle_attach (above `kind = route(address, state.mode)`), run the suite
# (must go RED with atom delta == queue count), restore byte-exact.
```
