# Receipt: kafka-exp4-repairs

- **Lane**: KAFKA-EXP4 (`/Users/sac/smalt`)
- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Owner files**: `lib/smalt/messaging/kafka/records.ex`, `lib/smalt/messaging/kafka/log.ex`

## Scope

EXPL-4 F3/F4 repairs on the Kafka Log/Records face, closed with a real-binary
Chicago court.

## F3 — recordsCount cross-check (silent tail-drop closed)

- `Records.parse_records/1` cross-checks the header `recordsCount` against the
  parsed record list: mismatch answers `{:error, :record_count_mismatch}` —
  a CRC-valid batch declaring 2 records with a malformed tail is refused
  typed, never partially admitted (header count 2, one record fanned out,
  watermark past undelivered records).
- `Log.admit_one/3` rides the cross-checked parse before store + journal
  append; `fan_out_eh/3` delivers exactly the verified record list.
- Court (real binary batches, real CRC32C): falsifier batch (recordsCount=2,
  1 valid record + `<<0xFF>>` tail) → `{:error, :record_count_mismatch}` at
  parse AND at `Log.produce/3`; hwm unchanged; fetch empty. Non-vacuity:
  well-formed 2-record batch parses to 2, stores (count 2), byte-exact
  fetch-back, BOTH records visible in the real EH store.

## F4 — unknown-partition reads answer error 3; index bounded

- `Log.partition_known?/2` (index < partition_count() AND topic known) gates
  ListOffsets v0/v1, Fetch v0, and Produce at the conn wire face; unknown
  {topic, partition} answers `Wire.error_code(:unknown_topic_or_partition)`
  (3), never an empty success; produce to an unserved index answers 3 and
  stores nothing.

## Additional repair landed (same surface, found by the court)

- `Log.fetch/3` was returning raw ETS tuples while its `@spec`/doc and the
  conn Fetch leg (`take_batches`) require `[%{base_offset, count, raw}]` —
  projected to the documented map shape (the coordinator checkpoint
  f06281af/8372edb6 landed this fix from the lane's in-flight tree).

## Court evidence

`MIX_BUILD_ROOT=_build-kfkx4 mix test test/internal/kafka_exp4_court_test.exs`
(run 2026-10-22, twice, both green; real listener boot each run):

```
$ MIX_BUILD_ROOT=_build-kfkx4 mix test test/internal/kafka_exp4_court_test.exs
04:43:59.576 info[] [kafka] listener bound on port 64627
Running ExUnit with seed: 673229, max_cases: 32
Finished in 0.2 seconds (0.00s async, 0.2s sync)
Result: 6 passed
```

(6 tests: F3 falsifier + 2 non-vacuity, F4 partition_known? unit, ListOffsets
wire error-3 vs known-partition-0 on a real TCP socket, produce-to-unserved-
partition error 3 + nothing-stored.)

Wire-face facts pinned by the court (debugging receipts):
- Kafka record lengths are SIGNED (zigzag) varints: valueLen 9 encodes 0x12;
  keyLen -1 encodes 0x01. Plain-unsigned LEB128 lengths parse as garbage —
  this is the encoding-12-vs-6 false lead named in the dispatch.
- ListOffsets v0 response block: `partition i32 | error_code i16 | ts i32 |
  offset i64` (partition BEFORE error); Produce request: acks(16) timeout(32)
  then the topics array (the array count is the first array field — a second
  count field desyncs the parse).
- Wire requests are size-prefixed (int32), responses size-prefixed (int32).

## Env note (pre-existing, not lane-introduced)

- `test/internal/kafka_wire_test.exs` (not lane-owned) observed 8/9..6/9
  across runs on this busy machine: its `expl4_req` helper sends requests
  WITHOUT the int32 size prefix (its F4 wire test cannot deliver a request),
  and the produce/consume probe flaked once with a PolicyViolationError(44).
  Flagged for the AZ-1 owner; not fixed here (file not in lane lease).

## Replay

```bash
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-kfkx4 mix test test/internal/kafka_exp4_court_test.exs
```
