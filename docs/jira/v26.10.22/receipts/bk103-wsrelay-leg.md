# BK-103: WsAmqpRelay BK-58 witness EH leg — close-out receipt

**Standing:** **ALIVE** (witness leg green solo ×5, full file green, relay+EH regression green at HEAD 73e882e)

Context: solo

## Carried defect (BK-82 census)

`test/internal/ws_amqp_relay_test.exs:206` "EH publish -> consume end-to-end
through the relay (BK-58 witness)" failed reproducibly solo (BK-82 census,
`docs/jira/v26.10.22/receipts/bk82-internal-census-green.md`).

## Court output

```
mix test test/internal/ws_amqp_relay_test.exs:206   # MIX_BUILD_ROOT=_build-bk103
Result: 1 passed, 1 excluded                        # x3 consecutive solo runs

mix test test/internal/ws_amqp_relay_test.exs
Result: 2 passed                                    # full file

mix test test/internal/ws_amqp_relay_test.exs test/internal/event_hubs_consumer_groups_test.exs
Result: 9 passed, exit 0                            # regression at HEAD 73e882e
```

First capture run (pre-fix, in-flight dirty tree): the leg failed with no EH
delivery (drain deadline, `xfers == []`) and then crashed inside the test's own
debug block — `:sys.get_state/1` timeout on a `Smalt.AmqpBroker.ConnSup` child.

## Root cause

Not a flow-law divergence. Evidence:

- The relay (`lib/smalt/messaging/ws_amqp_relay.ex`) is a domain-blind byte
  pipe; all AMQP state lives in `lib/smalt/messaging/amqp/connection.ex`. Its
  flow handler treats an inbound `:flow` as an ABSOLUTE link-credit snapshot
  (AMQP 1.0 §2.7.4, rhea `link.js on_flow` parity, KD-133 note) and replenishes
  via `deliver_available/1` on every flow — the test's fixed credit-10 windows
  on both receiver links are exactly what the broker honors.
- The witness run's credit accounting was correct throughout: the broker logged
  `[BK58-FLOW] credit=10` on the partition-0 receiver and polled
  `[BK58-DELIV] after_seq=0 credit=10` — credit was available and the cursor
  floor was 0; the poll found the store empty for that key at that moment.
- The failure decomposed into two instrumentation defects, not a
  credit/transfer bug:
  1. **Test-side debug block** (committed by the BK-58 lane "temporary,
     reverted after witness" but never reverted): on the failure path it ran
     `:sys.get_state/1` over every `ConnSup` child and timed out, converting a
     delivery-timing failure into a harness crash and destroying the real
     assertion (`assert xfers != []` sat AFTER the crashing block).
  2. **Stale debug beams**: `_build-bk103` carried BK-58/BK-78 hot-path
     `Logger.warning` instrumentation (`[BK58-FLOW]`, `[BK58-DELIV]`,
     `[BK58-DGB]` tcp push, `[BK78-DBG]` terminate/capacity probe) in
     `lib/smalt/messaging/amqp/connection.ex` and `ws_amqp_relay.ex`, compiled
     from the pre-cleanup sources; beams postdated the dirty debug-removal
     edits, so mix skipped recompilation and the first solo run executed the
     instrumented hot path (a `Logger.warning` inside the relay socket's
     `handle_info({:tcp, ...})` push, i.e. per-frame logging on the WS pipe).

Fix (minimal, matching the in-flight cleanup already owned by the BK-58 lane):
remove the hot-path debug instrumentation from
`lib/smalt/messaging/ws_amqp_relay.ex` + `connection.ex` (the capacity-clause
BK-78 probe detach-bytes shim was also dead code — the real detach below it was
intact and is preserved) and replace the test's crashing `:sys.get_state` debug
block with a fail-safe store probe (`EventHubs.last_enqueued/1` on both
partitions, only on the failure path). One `assert xfers != []` remains, after
the probe, as the gate.

Which side was wrong per the flow law: **neither side of the credit
accounting** — the relay/broker honors absolute-snapshot flow (real Azure EH
grants fixed windows; the broker replenishes on flow + delivers on
`deliver_available`). The wrong side was the harness: unreverted debug
instrumentation on the witness path.

## Concurrency disclosure

While this lane ran, the coordinator checkpoint `73e882e` ("BK-58 AMQP-over-WS
relay final PARTIAL_ALIVE") landed the lib debug removal and this lane's test
edit. HEAD at receipt time: `73e882e`. No commit made by this lane (per
dispatch: do not commit).

## Exits

- solo leg x3: exit 0 each
- full relay file: exit 0
- relay + `event_hubs_consumer_groups_test.exs` regression: exit 0
- BK-82 census residue row (WsAmqpRelay leg -> BK-58 owner): leg now closed
  green; residue reclassified from "consumer flow frame not reconciled" to
  "unreverted lane debug instrumentation" — no consumer-flow-frame divergence
  exists to register in `KNOWN_DIVERGENCES.md`.
