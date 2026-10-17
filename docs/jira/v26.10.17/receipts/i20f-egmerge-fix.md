# i20f — egress topic-readback merge: one seq domain (EG1 + CloudEvents)

Standing: ALIVE

## Defect

`GET /topics/:topic/events` (`lib/smalt/egress_router.ex`, readback merge)
merged `EventStream.list_events/1` (seq from the Store-owned
`{:seq_counter}` row in `:smalt_event_messages`) with
`ArmGateway.Router.eg_topic_events/1` (seq from the separate
`{:eg_seq_counter}` row in `:smalt_eg_topics`) and sorted the union by
`seq` — two non-comparable domains, so the merged insertion order broke
whenever the two counters diverged (e.g. any CloudEvents publish before the
topic flips to EventGrid, or vice versa, offsets one counter relative to the
other).

## Fix (minimal, re-domain option)

- `lib/smalt/messaging/event_stream.ex`: `next_seq/0` made public (`@doc` +
  `@spec next_seq() :: integer`) — doc states it is the shared seq domain for
  the readback merge.
- `lib/smalt/arm_gateway/router.ex` (`eg1_publish/2`): stamp seq from
  `Smalt.Messaging.EventStream.next_seq()` instead of
  `Store.update_counter(:smalt_eg_topics, {:eg_seq_counter}, 1)`. The
  `{:eg_seq_counter}` row is retired (tuple key was never in any
  `list_prefix` scan path).

No `eg_seq_counter` references remain outside the disclosing comment
(`grep -rn eg_seq_counter lib test gates` → comment line only).

## Re-witness disclosure (coordinator note honored)

`egress_router.ex` was edited earlier this window (HEAD conditionals +
request-id stamps, other lane). This lane's edits for the merge are only the
two hunks above: `lib/smalt/messaging/event_stream.ex` (next_seq public) and
`lib/smalt/arm_gateway/router.ex` (`eg1_publish/2` seq stamp). No
`egress_router.ex` edit was needed by this fix.

## Verification (real output)

```
$ MIX_BUILD_ROOT=_build-ft-egmerge mix test test/eventgrid_topics_arm_test.exs
15:29:04.721 [info] Running Smalt.ArmGateway.Router with Bandit 1.13.1 at 127.0.0.1:60531 (http)
15:29:04.727 [info] Running Smalt.EgressRouter with Bandit 1.13.1 at 127.0.0.1:60533 (http)
.
Finished in 0.5 seconds (0.00s async, 0.5s sync)
9 tests, 0 failures

$ MIX_BUILD_ROOT=_build-ft-egmerge mix test test/wire/egress_wire_test.exs
15:29:12.018 [info] [amqp] sb listener bound on port 60643
15:29:12.018 [info] [amqp] eh listener bound on port 60644
.
Finished in 1.1 seconds (0.00s async, 1.1s sync)
22 tests, 0 failures
```

Regression fence `test/wire/egress_wire_test.exs`: 0 failures. Exit 0 both.

## Scope

Lease honored: `lib/smalt/arm_gateway/router.ex` (eg1_publish hunk only),
`lib/smalt/messaging/event_stream.ex`, test files read-only. No git actions.
