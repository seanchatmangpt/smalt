# BK-117b — R-116-1 typed-exit closure (amqp10 tx/3)

**Standing:** **PASS** (R-116-1 closed; lib repair verified at HEAD, court extended + green)
Context: solo

## Subject

- Repo: /Users/sac/smalt, branch main. Lib state during run: HEAD 044fd23 (moved
  from 3a43886 mid-lane by concurrent tick checkpoint).
- Files: `lib/smalt/messaging/amqp10/amqp10_connection.ex` (tx/3),
  `test/integration/amqp10_bk116_skeptic.exs`.

## Finding (R-116-1)

`tx/3` was `:ok = :gen_tcp.send(state.socket, frame)` — a bare MatchError on
`{:error, :einval}` mid-death. Crash-only law holds; typed-exit discipline
violated. (`docs/jira/v26.10.21/receipts/amqp10-court-closure.md`, R-116-1.)

## Diff

### lib (verified at HEAD, not owned in this lane's diff)

The repair is **already landed at HEAD 044fd23** by a concurrent lane — byte
equivalent to the dispatched one-liner:

```elixir
case :gen_tcp.send(state.socket, frame) do
  :ok -> :ok
  {:error, reason} -> exit({:tcp_tx_error, reason})
end
```

This lane's Edit was a no-op against the updated disk state (compile-freeze
SLA disclosure: concurrent lane `044fd23` owns the lib hunk; BK-117b owns the
court leg). Verified on disk post-run: `lib/.../amqp10_connection.ex:221-224`.

### test (owned by this lane, UNCOMMITTED per dispatch)

`test/integration/amqp10_bk116_skeptic.exs` (+33/-1):

1. NEW test `R-116-1: mid-death tx crashes typed, never MatchError`: 8 bounded
   real-RST-race attempts over fresh connections (unique delivery ids
   800_101..800_108); asserts every observed DOWN reason is typed
   (`{:tcp_tx_error, _}` or `{:transport_closed, _}`, never
   MatchError/ArgumentError) and that at least one attempt witnessed the
   `{:tcp_tx_error, _}` tx/3 path directly (disjunctive law: race resolves
   either way, both typed — per no-sleep doctrine "prefer disjunctive laws
   when the mechanism is environment-dependent").
2. ADV-6 leg: DOWN-reason assertion strengthened from
   `refute ArgumentError` to the same typed disjunction.

## Court outputs

```
MIX_BUILD_ROOT=_build-bk117b mix test test/integration/amqp10_bk116_skeptic.exs
Result: 2 passed                                    exit 0

Crash report (real, from the run — the flip witness):
23:21:13.263 error[] GenServer #PID<0.2313.0> terminating
** (stop) {:tcp_tx_error, :closed}
    lib/smalt/messaging/amqp10/amqp10_connection.ex:225: Smalt.Amqp10.Connection.tx/3
    lib/smalt/messaging/amqp10/amqp10_connection.ex:104: handle_info/2
Last message: {:amqp10_tx, 0, {:disposition, %{first: 800001, state: :accepted, ...}}}
```

Witnessed typed reason this run: `{:tcp_tx_error, :closed}` (not `:einval` —
either typed reason closes the law; the pre-fix reason was bare MatchError).

Downstream courts (same build root, same run window):

```
MIX_BUILD_ROOT=_build-bk117b mix test \
  test/integration/amqp10_crash_only_court_test.exs \
  test/integration/ja7_crash_only_court.exs \
  test/integration/amqp10_skeptic_court.exs
Result: 19 passed                                   exit 0
```

Toolchain: asdf elixir 1.20.4-otp-29 / erlang 29.1.2 (mix.exs requires ~> 1.20;
homebrew elixir 1.19.5 refuses).

## Notes

- BK-116 scratch promote-or-delete: PROMOTED — file is now a proper ExUnit
  court (was already ExUnit-shaped; now carries the R-116-1 witness leg).
- Other lanes' uncommitted work observed in tree (e.g.
  `lib/smalt/messaging/event_hubs.ex` BK-70r orphan-reclaim) — untouched.
- Not committed, per dispatch.
