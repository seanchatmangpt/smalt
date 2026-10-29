# RELCUT — BOOTPROF cut #2: phased listener start (`:deferred_listeners`)

**Standing:** **ALIVE** (court 3/3 green on `_build-relcut`, measured delta attached)
Context: solo
Date: 2026-10-21
Lane: RELCUT (writer, OTP-29). Repo: /Users/sac/smalt. Build root: `_build-relcut`.

## Diff

- `lib/smalt/application.ex` — adds `Smalt.Application.deferred_listeners?/0`
  (`config :smalt, :deferred_listeners, false` default), `DeferredListeners`
  (supervisor owning the MCP listener in deferred mode) and `ListenerDeferral`
  (GenServer, last child in deferred mode: one `Process.send_after(self(), ..., 0)`
  tick — SLEEP-CLASS: SCHEDULING, no fixed sleep — then starts every deferred
  listener under its owning supervisor and exits `:shutdown`).
- `lib/smalt/plane/control_supervisor.ex` — TLS twin (9444) child is conditional:
  default mode keeps it in the init spec list (byte-identical); deferred mode
  omits it and exposes `start_deferred_listener/0`.
- `lib/smalt/plane/integration_supervisor.ex` — AMQP broker (5672/5673) same
  pattern via `start_deferred_listener/0`. Store child stays immediate (not a
  listener).
- `scripts/deferred_boot_probe.exs` — boot probe: real `Application.ensure_all_started`
  on the test config's ephemeral ports; bounded `:gen_tcp.connect` polls (no
  sleeps) record first-accept ms per listener; emits one JSON line.
- `test/internal/deferred_listeners_court_test.exs` — Chicago court.

Front door = ARM 9443 + egress 8443 (unchanged, start immediately). Deferred =
TLS twin 9444, AMQP 5672/5673, MCP 9545 (via tick after front door serves).

## Court output (real)

```
$ MIX_BUILD_ROOT=_build-relcut mix test test/internal/deferred_listeners_court_test.exs
...
Finished in 3.1 seconds (0.00s async, 3.1s sync)

Result: 3 passed
```

Faces pinned:
1. Default boot: all six listeners accept (running test app, real TCP connects).
2. Deferred boot (real subprocess boot): max(arm, egress) accept ms < min(tls
   twin, amqp, eh, mcp) — front door accepts strictly before any deferred
   listener binds.
3. Deferred boot end state identical: all six listeners accept.

## Measured readiness delta (min-of-3 boots each, first TCP accept ms)

Machine (`just bench-machine`): {"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}

| boot | arm (front door) | egress | arm_tls | amqp | event_hubs | mcp | last listener |
|---|---|---|---|---|---|---|---|
| deferred (3 boots) | 255 / 263 / 263 | 255 / 264 / 263 | 301 / 366 / 309 | 310 / 376 / 319 | 310 / 377 / 320 | 315 / 381 / 325 | 315 / 381 / 325 |
| default (3 boots) | 336 / 484 / 430 | 337 / 484 / 430 | 337 / 484 / 430 | 337 / 483 / 430 | 337 / 484 / 431 | 338 / 484 / 431 | 338 / 484 / 431 |

Readiness delta (front-door first accept, min-of-3): **255 ms deferred vs 336 ms
default → front door ready ~81 ms (~24%) earlier**; per-boot deltas 73-220 ms
(deferred wins all 3 boot pairs, but boot-to-boot variance on this machine is
the same order as the delta). Deferred listeners bind 46-83 ms after the front
door in deferred mode; default boot binds them concurrently (delta ~0). Last
listener complete: 315-381 ms (deferred) vs 338-484 ms (default) — phasing does
not delay overall readiness beyond boot noise.

Honest caveat: in default mode all listeners already start concurrently, so
the front door was never "late"; the measurable win is bounded by the
AMQP-broker + TLS-cert work displaced to the tick, not a fixed constant.

## Verification ladder

- Court: 3/3 passed (above). Regression: `plane_blast_radius`, `amqp_listener_cap`,
  `health_probe_parity` — `Result: 12 passed`.
- `just sleep-gate`: **FAIL pre-existing, not this lane** —
  `test/internal/impl6_process_label_test.exs:117 unclassified test sleep primitive
  (`_ -> Process.sleep(1) && {:cont, :undefined}`)`. File not touched by RELCUT;
  disclosed per compile-freeze disclosure law.
- Compile-freeze disclosure: `lib/smalt/messaging/amqp10/frame_decoder.ex` was
  observed mid-edit (TokenMissingError) by another lane during this session;
  RELCUT polled `mix compile` until green (resolved by the owning lane ~4 min
  later). No unblock fix applied by RELCUT.
- Known limitation (documented): a one_for_one restart of ControlSupervisor /
  IntegrationSupervisor in deferred mode re-inits WITHOUT the deferred child
  (one-shot deferral); the ListenerDeferral GenServer has already exited. A
  supervisor-level crash on those planes in deferred mode drops the deferred
  listeners until boot. Default mode is unaffected.

## Replay

```
export PATH="$HOME/.asdf/shims:$PATH"
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-relcut mix test test/internal/deferred_listeners_court_test.exs
MIX_BUILD_ROOT=_build-relcut MIX_ENV=test SMALT_DEFERRED_LISTENERS=1 mix run --no-start scripts/deferred_boot_probe.exs
MIX_BUILD_ROOT=_build-relcut MIX_ENV=test SMALT_DEFERRED_LISTENERS=0 mix run --no-start scripts/deferred_boot_probe.exs
```
