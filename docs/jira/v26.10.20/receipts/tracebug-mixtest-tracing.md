# TRACEBUG — root cause: trace_pattern "inert under mix test" = self-as-tracer event suppression

**Standing:** **ALIVE** (repro + positive control green, seed-stable, cross-OTP falsified)
Context: solo
Lane: Z1 root-cause (TRACEBUG writer), popcorn_demo subtree,
`MIX_BUILD_ROOT=_build-tracebug`, asdf OTP 29.0.6 / Elixir 1.20.4-otp-29.

## Witness

Z1 witnessed: `:erlang.trace_pattern({M,F,A}, _, [:local])` → ZERO call events
under `mix test` (flags verified set, `matched=16`, `:ets.insert/2` BIF
included) while "identical" code traced fine under `mix run` / raw `erl`.
Prior note in
`popcorn_demo/test/guideline_offline_test.exs` moduledoc even baked the
premise in ("call tracing under mix test is inert on this toolchain") — that
premise is now corrected: tracing works everywhere; only the tracer pid
choice was wrong.

## Repro artifact

`/Users/sac/smalt/popcorn_demo/test/trace_repro_test.exs` — three legs,
`@tag :tracebug`:

- A. self-as-tracer negative control: `:erlang.trace(self(), true, [:call])`
  + local-pattern calls ON self → zero events (the trap, asserted NONE).
- B. worker pid + dedicated tracer process + default-flag patterns → events
  for BOTH `:ets.insert/2` and `Target.ping/0` (the working pattern).
- C. worker + tracer with no active pattern (`MatchSpec=false` cleanup) →
  zero events (control: `trace/3 [:call]` with no pattern traces nothing).

Command + output:

```
$ cd /Users/sac/smalt/popcorn_demo
$ export PATH="$HOME/.asdf/installs/erlang/29.0.6/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH" MIX_BUILD_ROOT=_build-tracebug
$ mix test test/trace_repro_test.exs
...
Result: 3 passed          # seeds 1, 42, 777 and default seed: 3 passed each
```

Cross-OTP falsifiers (raw `erl`, both toolchains on this machine):

```
OTP 29.0.6 (erts 17.0.6):
  separate tracer + pattern        -> {trace,<0.10.0>,call,{lists,seq,[1,3]}}  EVENT
  self-as-tracer + same pattern    -> NONE
OTP 28.3.1:
  self-as-tracer + same pattern    -> NONE
  dbg:tracer() + dbg:p(all, call) + dbg:tp({lists,seq,2},[]) -> EVENT (prints)
```

## Root cause

A process never receives `:call` trace events for its own execution: ERTS
silently drops trace messages whose destination is the traced process
itself. Verified identical on OTP 28.3.1 and OTP 29.0.6 — longstanding
documented behavior, **not** an OTP 28.3/29 regression, **not** ExUnit
interference, **not** a compile/beam strip. The `mix test` witness made the
ExUnit runner process its own tracer and then called the traced functions on
it — every event was addressed to the traced process and discarded. "flags
verified set, matched=16" is precisely this surface: pattern and flags are
real, delivery is suppressed by destination. The `mix run`/`erl` runs that
"traced fine" used a spawned worker or a tracer fun — tracer pid ≠ traced
pid.

## Hypotheses falsified

- ExUnit async process-pool / runner interference: FALSIFIED — raw `erl`
  shows the same zero-event behavior with self-as-tracer; and leg B proves
  tracing works under ExUnit with a separate tracer.
- Compile strip (`--no-common-prefix`-style / beam without debug_info): 
  FALSIFIED — leg B traces the same compiled modules under mix test.
- OTP 28.3 regression vs Elixir test runner: FALSIFIED — OTP 28.3.1 shows
  the identical suppression; dbg on the same OTP 29 build traces fine.

## ExUnit-safe tracing pattern (proven by leg B)

1. Spawn the traced work on a worker pid (never trace the ExUnit process for
   its own calls).
2. Spawn a dedicated tracer process that forwards events to the test
   (`Task.start(fn -> tracer_loop(report_to, ref) end)`).
3. `:erlang.trace(worker, true, [:call, {:tracer, tracer_pid}])`.
4. Patterns: `:erlang.trace_pattern({M,F,A}, [], [])` — DEFAULT flag list
   (== local+global). On OTP 29 the explicit `[:local, :global]` list raises
   `badarg invalid option` (flags are per-call, mutually exclusive).
5. Cleanup with `MatchSpec=false`
   (`trace_pattern({M,F,A}, false)`), NOT `:pause` — `:pause` as a match
   spec PAUSES THE CALLING PROCESS (debugger semantics), it does not disable
   the pattern; on this toolchain it returns matched=1 while events keep
   flowing (witnessed, both OTPs).
6. Patterns are node-global and outlive their test — leg C disables leaked
   patterns explicitly instead of assuming a clean slate.

## Follow-ups (not done in this lane)

- `popcorn_demo/test/guideline_offline_test.exs` moduledoc premise rot
  ("call tracing under mix test is inert on this toolchain") can now be
  rewritten and the dynamic leg could add a real traced leg; left to the
  file's owner (lane boundary).
- `popcorn_demo/erl_crash.dump` (pre-existing, from the badmatch probes'
  first attempts; a fresh dump was written to /tmp and removed — the repo
  copy predates this lane).

## Toolchain receipt

```
otp 29 / erts 17.0.6 (asdf erlang 29.0.6); Elixir 1.20.4 (compiled with Erlang/OTP 29)
MIX_BUILD_ROOT=_build-tracebug
```
