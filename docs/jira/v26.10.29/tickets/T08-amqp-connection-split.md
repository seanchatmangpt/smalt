# T08 — Split `Smalt.Amqp.Connection` (3520 lines)

- window: v26.10.10 · status: QUEUED · class: decomposition

## Why

The AMQP connection actor mixes protocol framing concerns with delivery
semantics. 10 top-level defs but thousands of lines of clause bodies; the
pinion list in CLAUDE.md ("do not clean up" — SASL ANONYMOUS, descriptor
0x44, attach <=14 arity tripwires, GUID lock-token reorder, fixed
partitions) proves this file is byte-pinned by real-SDK censuses.

## Split plan (protocol-phase modules, behaviour-bounded)

- `Smalt.Amqp.Connection.Session` — channel/session endpoint state machine
  (begin/dispatch/flow/end).
- `Smalt.Amqp.Connection.Link` — attach/detach/flow + delivery routing.
- `Smalt.Amqp.Connection.Delivery` — settlement/disposition translation.
- `Smalt.Amqp.Connection.Handshake` — protocol-header + SASL + open
  negotiation (the pinion surface, isolated for byte-court protection).
- Connection root stays the crash-only actor (trap_exit root, link tree)
  and shrinks to delegation + state routing.

## Constraints

- The byte pinions are court-pinned by real-SDK censuses — Handshake
  extraction must keep byte-exact wire output; the wire tier
  (`mix test --include amqp_wire`) is the gate.
- No mock/interaction tests (house Chicago law); assert real frames.
