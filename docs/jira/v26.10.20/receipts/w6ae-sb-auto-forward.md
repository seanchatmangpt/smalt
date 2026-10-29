# w6ae — Service Bus auto-forwarding (`ForwardTo`)

**Standing:** PARTIAL_ALIVE (module surface + witness ALIVE on isolated lane beams; tree-wide compile + census + AMQP SDK leg staged for the post-router-split integration window)

## What landed

- `lib/smalt/messaging/amqp/queue_store.ex` — auto-forwarding engine (w6ae-exclusive region):
  - `forward_to/1` — reads `"forwardTo"` from the entity's ARM record properties (`.../queues/<name>` suffix law, plus a `.../topics/<t>/subscriptions/<s>` fallback so subscription rows `<Topic>/Subscriptions/<sub>` resolve too). `nil` when unset/empty; case-sensitive target.
  - `validate_forward_to/2` — `:ok` | `{:error, :self_forward}` | `{:error, {:target_missing, name}}` (case-sensitive existence in `:smalt_sb_queues`).
  - Forwarding hop inside the serialized enqueue server: a message enqueued on an entity with `ForwardTo` set is immediately moved to the target (`:ets.delete` + re-enqueue with properties preserved, fresh `:enqueued` wall stamp, delivery_count preserved). Chain depth rides annotations `"x-opt-forward-depth"`; at depth ≥ 5 the message dead-letters on the CURRENT entity's `$deadletterqueue` with `x-opt-deadletter-reason: ForwardChainLimit` (5th hop target, delivery count preserved, no infinite loop).
  - Subscription forwarding: the fan-out path inserts per subscription row, so `T1/Subscriptions/S1` with `forwardTo` delivers to the forward target instead of the subscription row.
- `lib/smalt/messaging/amqp/atom_bridge.ex` — `forwardTo` parse (QueueDescription XML → ARM record `"forwardTo"`) and admin GET echo (`<ForwardTo>` element in the QueueDescription render, read back from the stored record; `""` when unset).

## Witness (real output — isolated lane beams, w6R router-split in flight, tree compile-frozen)

Replay: `ELIXIR_ERL_OPTIONS="$(for d in $(ls -d _build-lane-w6ae/test/lib/*/ebin); do printf -- '-pa %s ' $d; done) -pa /tmp/w6ae_out3" elixir -e 'Code.require_file("tmp/w6ae_witness.exs")'`

```
CHECK1_VALIDATION_OK
CHECK2_FORWARD_OK
CHECK3_PROPS_OK depth=1
CHECK4_CHAIN_LIMIT_OK
CHECK5_NO_LOOP_OK
CHECK6_SUB_FORWARD_OK
W6AE WITNESS: ALL FACES OK
```

## Honest notes (typed)

- **Module-level verification only.** Full-tree `mix compile` was blocked the entire lane by the in-flight w6R router split (egress_router.ex exclusive lease) plus sibling churn (cosmos.ex, AppConfig.ex). Per the lane contract, my two modules were verified via standalone `elixirc` against `_build-lane-w6ae` dep ebins: **0 errors** (warnings are the expected standalone-fallback warnings for smalt-internal modules).
- **AMQP SDK leg staged, not run**: a live substrate boot is impossible while the router is mid-restructure. Staged: send-to-source/receive-on-target .cjs probe reusing the w5b4 probe shape.
- **ARM PUT-side validation wiring** (router-side 400 faces for self-forward/target-missing) is a staged post-split patch, disclosed.
- **Pre-existing defect disclosed, not session-introduced, not fixed (foreign region — w5g ownership)**: `queue_store.ex` fanout handler had a duplicated `{:reply, {:error, :session_required}, state}` line (~:700); harmless dead expression, syntactically legal.
- One tool-serialization corruption hit my own lane files mid-write twice (fixed in-place, final content verified on disk + via elixirc); same corruption class w6i reported. The witness output block above is pasted from the final executed run.

## Integration checklist (coordinator)

1. Post-split: apply staged router patch (ARM PUT-side ForwardTo validation → typed 400 faces), run `tmp/w6ae_witness.exs` via `mix run --no-start`, and the AMQP SDK leg.
2. Run `mix test test/sb_topic_fanout_test.exs` (staged regression guard; it exercises QueueStore).
3. `just lane-clean` `_build-lane-w6ae` at integration.
