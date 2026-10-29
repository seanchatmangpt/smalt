# Receipt: bkamqpf-f2a-boundary (F2a disposition)

**Standing**: CLOSED — by upstream repair (boundary already typed end-to-end, zero code change)
**Context**: solo
**Lane**: BK-AMQPF, repo /Users/sac/smalt, build root `_build-bkamqpf`
**Subject**: `lib/smalt/messaging/amqp10/amqp10_connection.ex` (probe-only — ZERO code change),
court test `test/internal/bkamqpf_f2a_boundary_court_test.exs` (new)

## Finding (F2a)

Claimed residual: a malformed frame body could raise an untyped error out of
the AMQP10 connection process's decode/commit path instead of exiting typed.

## Disposition: CLOSED-BY-UPSTREAM-REPAIR

Probe at the real process boundary (real TCP, real connection process, real
crash — no mocks, no sleeps) over the wire_exp4 corrupt-frame corpus proves
the boundary is already typed end-to-end:

- `FrameDecoder.decode_frame/1` answers `{:error, :truncated_frame | :bad_element}`
  for every corpus class (wire-exp4 + skepr1/skepr2 repairs).
- `pump_frames/2` maps that to `{:exit, {:bad_frame, reason}}`
  (amqp10_connection.ex:172-173); `handle_info({:tcp,...})` maps `{:exit, r}`
  to `{:stop, r, state}` (amqp10_connection.ex:93-98).
- Observed connection-process terminations under the corpus are exactly
  `(stop) {:bad_frame, :truncated_frame}` and `(stop) {:bad_frame, :bad_element}`
  — typed tuple reasons, never a raw exception struct, never catch-and-continue.
  Crash-only law preserved (the process exits; it does not swallow the frame).

No rescue was needed at the connection; the only prior untyped raise
(sized-element truncation) was eliminated upstream. The connection surface
carries no new code; a boundary rescue added now would be dead armor.

## Court

`test/internal/bkamqpf_f2a_boundary_court_test.exs` — 3 tests, 9 corpus legs,
all through `Connection.start_listener/2` + real `:gen_tcp` client:

1. 9-leg corpus (truncated 0xA0/A1/A3/B0/B1/B3/0x98 -> `:truncated_frame`;
   0xC0 trailing-byte-in-declared-slice and 0xC1 odd-count -> `:bad_element`),
   each on a fresh connection, asserting the exact DOWN reason
   `{:bad_frame, :truncated_frame | :bad_element}` — a raw MatchError /
   FunctionClauseError struct here is a court failure, as is surviving the
   hostile frame.
2. EXPL-4 F2 witness frame (declared 200-byte str8, 3 bytes follow) exits
   typed at the process boundary.
3. Non-vacuity: a well-formed `:open` frame decodes, is answered, and the
   connection does NOT die (refute_receive DOWN) — the court cannot pass on
   a connection that kills everything.

```
$ MIX_BUILD_ROOT=_build-bkamqpf mix test test/internal/bkamqpf_f2a_boundary_court_test.exs
...
Finished in 55.6 seconds (0.00s async, 55.6s sync)

Result: 3 passed
```

Non-vacuity of the probe itself: the run's logger output shows the real
terminations, e.g.

```
04:45:07.953 error[] GenServer #PID<0.2962.0> terminating
** (stop) {:bad_frame, :truncated_frame}
```

Note: `scripts/fast_test.sh`-class PATH hazard reconfirmed — homebrew elixir
must not shadow `$HOME/.asdf/shims`.

## Commit

Both files staged by explicit path; no other tree changes (git status was
checked at lane start; the file named `connection.ex` in the order is
`amqp10_connection.ex` on disk and was clean).
