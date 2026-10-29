# IMPL-4 — AR-OBS-01 trace-session court (v26.10.21)

**Standing:** **ALIVE** (3/3 legs PASS, seed-stable 3 consecutive runs)
Context: solo
Lane: IMPL-4 (OTP-29 lane, writer), repo `/Users/sac/smalt`,
`MIX_BUILD_ROOT=_build-impl4`, toolchain TOOLUP: erlang 29.1.2 /
elixir 1.20.4-otp-29 (asdf installs, PATH-prefixed; `.tool-versions` is the
repo pin).

## Artifact

`test/integration/trace_session_court.exs` —
`Smalt.Test.Internal.TraceSessionCourtTest`, `async: true`, three legs:

1. **Isolation gate (court A)** and duplicate court B: two ExUnit-async
   tests run concurrently, each with its own
   `trace:session_create/3` session (dedicated counting tracer process per
   session), both tracing the SAME MFA
   `Smalt.EgressRouter.egress_cors/2` via session-scoped
   `trace:function(Session, MFA, [], [:local])` + `trace:process(Session, :all, true, [:call, :set_on_spawn])`,
   while 20 concurrent cosmos-path ops (`GET /dbs/...`) run through the REAL
   `Smalt.EgressRouter.call/2` plug pipeline (`Plug.Test` conns on Task
   processes — real router, real conn, real 404/401/200 faces). Each session
   records ALL 20/20 events, zero cross-drop; order-independence warmup leg
   (5 more ops after both books exist) also 25/25 cumulative for both
   sessions. Polls are the audited poll helper (`SmaltTest.Internal.Poll.eventually/2`,
   `Code.require_file("poll_helper.exs", ...)`); zero fixed sleeps.
2. **Cross-drop cross-check** (folded into leg 1): `ca == cb == 20` then
   `== 25` cumulative, so neither session dropped frames and neither saw the
   other's bookkeeping.
3. **TRACEBUG boundary pin**: tracer = self, self executes 5
   `queue_plane_route/3` calls → bounded deadline-checked absence window
   counts **0** events (destination-based suppression preserved under
   sessions); positive control on the SAME session (worker spawned from the
   flagged test process, `:trace.process(S, :all, ...)` armed) delivers
   **5/5** — proving the zero is destination suppression, not dead
   patterns/flags. This documents what isolation does NOT fix (v26.10.20
   TRACEBUG receipt, `docs/jira/v26.10.20/receipts/tracebug-mixtest-tracing.md`:
   ERTS drops call-trace events whose destination is the traced process).

## Command + output

```
$ cd /Users/sac/smalt
$ PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH" \
  MIX_BUILD_ROOT=_build-impl4 mix test test/integration/trace_session_court.exs
Running ExUnit with seed: ...  max_cases: 32
...
Finished in 0.3 seconds (0.3s async, 0.00s sync)

Result: 3 passed
```

Re-run 3x: `Result: 3 passed` x3 (seed-stable).

## API facts pinned (kernel trace.erl, OTP 29.1.2, kernel-11.0.3)

- `trace:session_create(Name, Tracer, Opts)` with `Opts :: []` — works.
- Session is the FIRST argument: `trace:process(Session, Procs, How, FlagList)`,
  `trace:function(Session, MFA, MatchSpec, FlagList)`,
  `trace:system(Session, Event, Value)` (not `trace:system/2` — that form is
  `undef`/`badarg` everywhere probed, including OTP 28.3 and 29.0.6).
- Session ops return `badarg` on OTP 28.3.1 and on 29.0.6-with-OTP-28-kernel
  path — the court requires the OTP 29 toolchain (TOOLUP).
- Call-trace event tuples carry the ARGUMENT LIST
  `{trace, Pid, :call, {M, F, Args}}`, not the arity — matchers must match
  args.

## Cross-lane disclosure (compile-freeze SLA)

- The shared `lib/` compile was frozen by in-flight OTP-29-lane edits while
  this lane built `_build-impl4` from cold: `graph_compat.ex` transient
  syntax corruption (owner fixed within one poll cycle), and
  `is_integer/3` guard heads in `blob_storage.ex`, `file_share.ex`,
  `cosmos.ex`, `egress_router.ex` that do not compile on OTP 28 (this lane's
  initial builds used the ambient OTP 28 toolchain). This lane applied
  mechanical unblock rewrites (three-arg `is_integer(x, lo, hi)` →
  `defguardp int_in(x, lo, hi)` equivalents) in those four files; IMPL-2
  subsequently re-pinned `egress_router.ex` (AR-WIRE-02) and the tree now
  compiles green under the TOOLUP OTP 29 toolchain where the original
  `is_integer/3` form is a real guard BIF. Any `defguardp int_in` residue
  in those four files is this lane's unblock shim and is superseded by
  IMPL-2's re-pin — coordinator may drop the shims at integration.
- `queue_plane_route` is arity 3 (method, segments, qp-map), not 4.

## Falsifiers

- A session that drops events under concurrent load: isolation-gate asserts
  exact 20/20 + 25/25 for both sessions, deadline-checked, fail-closed.
- A future ERTS that delivers self-events: TRACEBUG negative leg fails.
- A future session API that loses per-session flag independence: courts
  recording fewer than the workload count fail.
