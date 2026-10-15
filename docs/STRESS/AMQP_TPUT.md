# AMQP Throughput

Max-throughput AMQP benchmark: raw `FrameCodec` Elixir driver over `:gen_tcp`
(`scripts/stress/amqp_tput_driver.exs`), orchestrated by the python harness
(`scripts/stress/amqp_throughput.py`).

## Run

```sh
python3 scripts/stress/amqp_throughput.py           # 60s x 2 phases
SMALT_TPUT_DURATION=8 SMALT_TPUT_PAYLOAD=1024 python3 scripts/stress/amqp_throughput.py
```

- Phase A: 1 connection, 1 sender + 1 receiver, credit window 100, 1KB payloads.
- Phase B: 4 parallel sender/receiver pairs on 4 queues (4 connections).
- Round trip = send -> receive -> disposition(accepted) -> broker complete.
- Receipt: `tmp/amqp-tput-receipt.json`; substrate/driver logs in `tmp/amqp-tput-*.log`.

## Results (2026-10-14, 1KB, 60s per phase)

| phase | sent | completed | round-trip mps | latency p50 / p90 / p99 / max (ms) |
|---|---|---|---|---|
| A solo (1 pair) | 62,701 | 62,701 | 1,045.0 | 479 / 541 / 613 / 634 |
| B quad (4 pairs) | 65,629 | 65,629 | 1,093.8 | 454 / 506 / 543 / 571 |

Errors: zero. Send == completed in both phases (no drops, no leaks).
Quad aggregate ~= solo, i.e. one connection already saturates the substrate.

## Latency shape

The embedded-timestamp latency distribution (~480ms p50) is queue-wait under
max offered load, not first-frame latency: the driver keeps up to 500 transfers
in flight, so most of the measured time is time-in-queue ahead of the receiver,
by construction. It is not comparable to the census first-frame p95 budget
(< 100 ms); the receipt records both separately.

## Known open item (broker, not driver)

The broker's `Smalt.Amqp.Connection.ingest_message/4` does not trigger a
dispatch pass after `QueueStore.enqueue/3` — queued messages are only
dispatched inside `deliver_available/1`, which currently runs on client `flow`
frames. A receiver that grants credit once and goes quiet never receives.

The driver accommodates this from its side of the wire by sending a credit
refresh (`flow handle=1 link_credit=100`) with every send burst and on receive
timeouts, giving the broker a dispatch pass per burst. Fixing the broker
(dispatch-on-enqueue in `lib/smalt/messaging/amqp/connection.ex`) is outside
this lane's owned files; until then this benchmark measures round-trip
throughput with driver-driven dispatch.

## See Also

- `docs/STRESS/AMQP_FANOUT.md`
- `docs/BENCHMARKS.md` (census budget)
