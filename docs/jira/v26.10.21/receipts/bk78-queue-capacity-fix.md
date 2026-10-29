# BK-78 queue-capacity gate fix — v26.10.21

**Standing**: **ALIVE** — gate verdict PASS, exit 0, reproduced 2x; all 4 negative fixtures refused (non-vacuous); adjacent AMQP internal tests 5/5 pass.
- **Context: solo**

## Root cause (evidence-typed, two stacked defects)

The BK-72 FAIL ("socket-closed vs amqp:link-message-size-exceeded") was real
but mis-typed: the divergence the wire showed was downstream of two defects.

1. **Gate premise rot (KD-86)**: `gates/queue_capacity_gate.py` never
   materialized `gate-capq`. Under KD-86 real-SB semantics (`sb_auto_ensure`
   default OFF), the first fill transfer got `messaging_entity_not_found`,
   the broker detached the sender link (`amqp:not-found`) and deleted it,
   and the remaining fill flood then error-closed the connection on
   "transfer on unknown handle 0" -> `amqp:internal-error` socket close.
   Server-side debug witnessed every step (instrumented
   `terminate`/clause logging, then removed):
   - `transfer unknown-handle links=[{0, 2}, {0, 3}]` (queue link gone)
   - `terminate reason=:normal links=[{0, 2}, {0, 3}] halted=true`
   `lock_clamp_gate.py` (same driver) already created its queues via ARM —
   the capacity gate predated the KD-86 behavior change and was never
   updated. Classic premise rot.
2. **Lib divergence (Azure-exactness)**: even with the queue created, the
   `{:error, :capacity}` ingest clause routed to `error_close` —
   connection-killing. Real Service Bus / AMQP 1.0 spec §2.8.15 faces a
   quota/size refusal as a SENDER-LINK DETACH with
   `amqp:link:message-size-exceeded`, connection survives (same family as
   the KD-86 `amqp:not-found` link-detach precedent in the same file, incl.
   the BK-65 witness that the link must also leave `state.links`).

## Fix

- `lib/smalt/messaging/amqp/connection.ex` — `{:error, :capacity}` and
  `{:error, :too_large}` now detach the sender link with
  `amqp:link:message-size-exceeded` (description names `:capacity` /
  `:too_large`), delete the link from `state.links`, connection survives.
  Generic `{:error, reason}` clause retyped to `amqp:internal-error` (it
  was mislabeling non-size errors as message-size).
- `gates/queue_capacity_gate.py` — creates `gate-ns` (LRO-polled) and
  `gate-capq` via ARM PUT before driving the wire; verdict now pins
  condition `amqp:link:message-size-exceeded`, `:capacity` in description,
  AND `survived` (connection survives). New 4th fixture
  `connection-killed` (detach-with-error but socket died = the OLD
  divergent face) is refused — survival is load-bearing.
- `gates/amqp_invariant_driver.exs` — capacity mode reads the ruling from
  a detach-with-error (read_until_ruling), proves survival via a bounded
  recv probe (timeout = alive, closed = killed), and fixes error-field
  extraction: AMQP errors decode as `{:described, 0x1D, [{:symbol, cond},
  desc, info]}` tuples — the old reader only handled maps/lists, so even a
  correct wire error read as nil (unit round-trip witnessed:
  `DECODED %{performative: %{error: {:described, 29, [{:symbol, ...}]}}}`).

## Before / after

BEFORE (BK-72 receipt, deterministic 2x):

```
FAIL queue-capacity/positive: ['FAIL broker closes with amqp:link-message-size-exceeded (got socket-closed)', ...]
3/3 fixtures refused; verdict=FAIL, exit 1
```

AFTER (both runs, no manual PATH prefix):

```
PASS queue-capacity/positive: ['PASS broker detaches link with amqp:link:message-size-exceeded (got amqp:link:message-size-exceeded)', 'PASS detach description names :capacity (got "The entity \'gate-capq\' is at capacity (4096 messages); the sender link was detached (:capacity). The connection remains open.")', 'PASS connection survives the link detach (got True)']
PASS queue-capacity/fixture:overfill-accepted (refused: ...)
PASS queue-capacity/fixture:wrong-condition (refused: ...)
PASS queue-capacity/fixture:silent-socket-drop (refused: ...)
PASS queue-capacity/fixture:connection-killed (refused: ...)
queue-capacity: receipt .../tmp/invariant-gates/queue-capacity-receipt.json verdict=PASS
```

Exit 0 both runs. No-over-refusal witness: the positive fill is exactly
4096 settled transfers and all were accepted (the capacity ruling fires
only on the 4097th) — a frame just under the limit succeeds.

## Verification ladder

- Gate positive + 4 mutation fixtures vs live substrate: PASS, 4/4 refused.
- Adjacent internal tests (`bk27_kd86_auto_ensure_gate_test`,
  `kd115_credit_first_delivery_test`, `kd134_requester_delivery_test`):
  5 passed.
- Wire-truth method note: the old gate's close-frame reader could NEVER
  match a broker error frame — the `{:described, 0x1D, ...}` decode shape
  was unknown to it — so the pre-BK-78 "expected" condition string was
  unobservable on the wire (receipt r82's PASS lines show fixture-mutated
  strings, not wire observations).

## Falsifier / replay

```
MIX_BUILD_ROOT=_build-bk78 python3 gates/queue_capacity_gate.py   # exit 0, verdict=PASS x2
mix test test/internal/bk27_kd86_auto_ensure_gate_test.exs \
         test/internal/kd115_credit_first_delivery_test.exs \
         test/internal/kd134_requester_delivery_test.exs          # 5 passed
```

Logs: `/tmp/bk78-sub*.log` (substrate boots + instrumented traces).
Scratch drivers removed; lib/gate files carry no debug residue
(`grep BK78` clean except this receipt).
