# AZ-1c — Kafka wire face receipt (BK-122r relaunch)

**Standing:** ALIVE
**Context: solo** (one lane on the canonical checkout; two compile-freeze SLA polls
during the wave for other lanes' in-flight `journal_sink.ex` edits — other lanes' files,
disclosed to the wave ledger, not this lane's).

Subject: HEAD 353d9470 at gate time (this lane's kafka edits landed via coordinator tick
checkpoints f06281af / 61ecfc39 / 36a8b74c + working-tree state at gate time). Subject
files: `lib/smalt/messaging/kafka/{conn,log,records,wire,listener,supervisor}.ex`,
`scripts/az1/kafka_probe.py`, `scripts/az1/kafka_negative_probe.py`,
`test/internal/kafka_wire_test.exs`.

## Repairs landed this lane (7 wire defects against kafka-python-ng's wire schemas)

1. **Metadata v1** emitted a bogus `cluster_id` (a v2+ field) and omitted `is_internal`
   per topic — every downstream byte misparsed, so the client never resolved the topic
   (`KafkaTimeoutError: Failed to update metadata after 60.0 secs`). Fixed to the v1
   schema: rack per broker, controller_id, is_internal per topic.
2. **Produce v0/v1/v2 responses** omitted the leading `partition i32` in partition blocks
   and put `throttle_time_ms` at the head instead of after the topics array.
3. **Fetch v0 response** emitted `error, partition, hwm` — the client schema is
   `partition, error_code, highwater_offset, message_set` — and only v0 was served while
   the negotiated client sends **Fetch v2** at broker (0,10,0). Now partition-first and
   Fetch v1/v2 served (matrix `1 => {0, 2}`, throttle head for v1+).
4. **ListOffsets v0/v1 responses** emitted `error, partition, ...`; the spec order is
   `partition i32, error_code i16` first.
5. **`Log.produce` handle_call** destructured `{reply, _} = Enum.reduce(...)` — a 2-tuple
   error `{:error, :record_count_mismatch}` destructure made produce answer bare `:error`,
   swallowing the typed refusal reason.
6. **`Log.fetch/3`** returned raw ETS tuples — `take_batches` on the fetch leg crashed
   (`FunctionClauseError`) and consumers received zero records. Projection to the
   documented `%{base_offset, count, raw}` shape landed by the EXPL-4 lane fold in the
   same window; verified on disk and exercised by this gate.
7. **Court-side defects:** the F3 batch builder encoded plain LEB128 where
   record-format-v2 varints are zigzag (the parser was right to refuse; builder fixed);
   F4 requests lacked the 4-byte size prefix (server buffered forever → recv timeout);
   F4 expected the old wrong response layout (partition-first now asserted);
   `"expl4-nope-topic"` length asserted as 17 instead of 16; `recv_resp` assumed one
   response per recv (two responses arrived in one TCP segment → buffered size-prefixed
   reader with per-socket stash).

## Legacy message-set face (registered as KD-174)

With the served ApiVersions matrix, real clients infer broker (0,10,0) and produce with
**legacy magic-0/1 message sets** (IEEE CRC32), which the face previously refused
(`:bad_message_set_frame` kill). The face now: parses legacy frames (min frame 26 bytes),
verifies IEEE CRC32 (`:erlang.crc32`) on the legacy face vs CRC32C on magic-2, counts and
parses legacy records (null key/value face, timestamp field on magic 1), stores legacy
frames WITH their `{offset, size}` wrapper (so the broker-stamped offset survives journal
replay byte-exact — `base_offset_of/1` reads it uniformly at bytes 0..7), patches the
offset at bytes 0..7 for both magics (CRC-neutral in both layouts), and re-serves legacy
frames verbatim on fetch (magic byte at index 16 in both stored shapes; magic-2 stored
bare and re-framed at fetch). Sealed-journal replay was witnessed restoring 6 batches
(produce5's 5 + seal test's 1) with byte-exact fetch-back. Magic-2 remains served
fail-closed at the wire tier (CRC32C, crash-only kill — the negative probe's named
falsifier). Registered as **KD-174** (v26.10.22 pointer + canonical v26.10.14 table;
mint header bumped to KD-175). No `# KD-COVERS` shim (registration-only row).

## Verification ladder (real gates, actual exits)

```
$ MIX_BUILD_ROOT=_build-bk122rr mix compile
COMPILE_EXIT=0

$ MIX_BUILD_ROOT=_build-bk122rr mix test test/internal/kafka_wire_test.exs
Running ExUnit with seed: 22143, max_cases: 32
Result: 9 passed
TEST_EXIT=0
```

Stability: 7 of the last 8 runs green; the one non-green run (seed 324683-class ordering,
earlier in the repair sequence) was a mid-repair state, not a current flake. The last 5
consecutive runs: 9 passed × 5 (seeds 422715, 433041, 865371, 653819, 395803), plus the
final gate 9 passed (seed 22143) — 6 consecutive green.

## Probe transcripts (real clients, real TCP, no mocks)

```
$ MIX_ENV=test SMALT_TEST_KAFKA_PORT=0 MIX_BUILD_ROOT=_build-bk122rr \
  mix run /tmp/receipt_probes.exs        # boots the app, ephemeral kafka port

KPORT=55296
[probe produce] exit=0
PRODUCED ["az1-msg-1-7108", "az1-msg-2-7172", "az1-msg-3-7236", "az1-msg-4-7300", "az1-msg-5-7364"]
[probe consume] exit=0
PASS consume byte-exact n=5
[negative probe] exit=0
PASS bad-CRC conn killed
PASS produce-v9 conn killed
SUMMARY: 2/2 PASS
```

- Produce leg: kafka-python-ng `KafkaProducer` over real TCP: 5 values, byte-exact ack.
- Consume leg: `KafkaConsumer` assign + seek_to_beginning, byte-exact fetch-back
  (`PASS consume byte-exact n=5`).
- Negative (crash-only) legs: bad-CRC magic-2 batch and Produce v9 (first flexible
  version) both kill the connection — the lane falsifier — `SUMMARY: 2/2 PASS`, exit 0.
- EH fan-out: the court's produce5 test asserts the fan-out leg via
  `Smalt.Messaging.EventHubs.receive_events/2` on both partitions (court 9/9 includes it).

## Falsifiers

- F3 (recordsCount mismatch is typed, never a silent tail drop) — court-exercised.
- F4 (unknown {topic, partition} reads answer error 3 on the real wire) — court-exercised.
- Crash-only law (bad CRC / unsupported flexible version kill the connection) — probe-exercised.
- KD-174 falsifier (a real client negotiates magic-2 produce through this listener) remains open.

## Boundary / not landed here

- No commits made by this lane (per brief); edits landed via coordinator tick checkpoints.
- KD-174 is OPEN; the flip is receipt-gated via `scripts/kd_flip.py`.
- Receipt index regeneration (`just receipt-index`) and commit left to the coordinator.
