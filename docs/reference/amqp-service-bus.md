# amqp-service-bus

AMQP 1.0 Service Bus (5672) and Event Hubs (5673) planes. Generated from the
code surface.

## Modules

Derived: `grep -h "^defmodule" lib/smalt/messaging/` (recursive).

| module | file |
|---|---|
| `Smalt.AmqpBroker` | `lib/smalt/messaging/amqp_broker.ex` |
| `Smalt.Messaging.EventHubs` | `lib/smalt/messaging/event_hubs.ex` |
| `Smalt.Messaging.EventStream` | `lib/smalt/messaging/event_stream.ex` |
| `Smalt.Amqp.AtomBridge` | `lib/smalt/messaging/amqp/atom_bridge.ex` |
| `Smalt.Amqp.CbsRouter` | `lib/smalt/messaging/amqp/cbs_router.ex` |
| `Smalt.Amqp.Connection` | `lib/smalt/messaging/amqp/connection.ex` |
| `Smalt.Amqp.DeliveryEncoder` | `lib/smalt/messaging/amqp/delivery_encoder.ex` |
| `Smalt.Amqp.FrameCodec` | `lib/smalt/messaging/amqp/frame_codec.ex` |
| `Smalt.Amqp.Listener` | `lib/smalt/messaging/amqp/listener.ex` |
| `Smalt.Amqp.ManagementRpc` | `lib/smalt/messaging/amqp/management_rpc.ex` |
| `Smalt.Amqp.PrimitiveCodec` | `lib/smalt/messaging/amqp/primitive_codec.ex` |
| `Smalt.Amqp.QueueStore` | `lib/smalt/messaging/amqp/queue_store.ex` |
| `Smalt.Amqp.LockManager` | `lib/smalt/messaging/amqp/lock_manager.ex` |
| `Smalt.Amqp.Sweeper` | `lib/smalt/messaging/amqp/sweeper.ex` |
| `Smalt.Amqp.SasVerifier` | `lib/smalt/messaging/amqp/sas_verifier.ex` |
| `Smalt.Messaging.EventHubs.Listener` | `lib/smalt/messaging/event_hubs/listener.ex` |

## Config keys

| key | default | call site |
|---|---|---|
| `:amqp_port` | `5672` | `messaging/amqp/listener.ex` |
| `:event_hubs_port` | `5673` | `messaging/event_hubs/listener.ex` |
| `:sb_endpoint` | `"sb://127.0.0.1:5672"` | `config/config.exs:37` |
| `:sb_shared_key` | `nil` (dev key cached in `:persistent_term`) | `config/config.exs:38` |
| `:amqp_sweeper_tick_ms` | `250` | `messaging/amqp/sweeper.ex` |
| `:amqp_sweeper_lock_grace_ms` | module `@default_grace_ms` | `messaging/amqp/sweeper.ex` |
| `:event_stream_dedup_ids` | `false` | `messaging/event_stream.ex` |
| `:primitive_codec` | see `messaging/amqp/primitive_codec.ex` | `messaging/amqp/primitive_codec.ex` |

## Refusal vocabulary

Generated from `lib/smalt/messaging` refusal atoms + `$management` codes:

- `$management` 501 `UNSUPPORTED_OPERATION` for unimplemented SB ops:
  schedule-message (KD-47), session-state ops (KD-72),
  get-message-sessions (KD-73), batch-delete-messages (KD-74); EH mgmt ops
  501 (KD-19)
- 401 `AuthenticationFailed` via `SasVerifier`/`CbsRouter` (401 class in
  ERROR_CODES `egress-auth`)
- atoms: `:not_found`, `:unauthorized`, `:invalid_cloudevent`,
  `:invalid_length`, `:invalid_constructor`, `:session_required`,
  `:session_lock_lost`
- 409 `WriteConflict` on queue-capacity violation (fail-closed gate
  `gates/queue_capacity_gate.py`)

## KD cross-links

Canonical register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.

- KD-18 EH transfer omits message_format
- KD-19 EH $management 501
- KD-20 EH credit not decremented
- KD-21 open-frame trailing-null trim crashes pyamqp
- KD-45 SB management ATOM+XML queue create
- KD-46 deferred redelivery no deliveryCount
- KD-47 scheduleMessage unimplemented
- KD-49 attach echo omits fields (source=8/target=7 composite arity
  tripwires — wire pinion, see repo CLAUDE.md)
- KD-50 queue properties camelCase readback
- KD-51 SB admin client URL space
- KD-53 EH multi-event batch delivers one
- KD-68 selector-filter (eventPosition) ignored
- KD-69 epoch not enforced
- KD-70 delivery_annotations absent
- KD-71 x-opt-offset annotations
- KD-72 session-state ops 501
- KD-73 get-message-sessions 501
- KD-74 batch-delete-messages 501
- KD-77 delivery-tag encoding (settle path)
- KD-84 settlement race on receiver close
- KD-85 enqueuedTimeUtc annotation key mismatch
- KD-86 auto-ensure divergence
- KD-88 checkpoint-store pump warm-up race

## See Also

- `docs/WIRE_PARITY.md` (GAP token register)
- `docs/reference/kd-register.md`