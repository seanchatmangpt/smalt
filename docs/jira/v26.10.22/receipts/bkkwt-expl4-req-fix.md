# Receipt: bkkwt-expl4-req-fix

- **Lane**: BK-KWT (`/Users/sac/smalt`)
- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Owner file**: `test/internal/kafka_wire_test.exs`

## Scope

KAFKA-EXP4-flagged repair of `test/internal/kafka_wire_test.exs` (`expl4_req/3`
size-prefix face) + F4 response-parse verification + PolicyViolationError(44)
flake rerun + kafka_exp4 court regression.

## State found on disk (in-flight lane edits, disclosed)

The working tree already carried this lane's two in-flight edits to the owned
file, both verified against the KAFKA-EXP4 reference court semantics:

1. `expl4_req/3` now prefixes the int32 size
   (`<<byte_size(header_body)::unsigned-32>> <> header_body`) — HEAD
   (`44b80f26`) already contained this; the receipt's flagged defect is closed
   in the current tree.
2. `recv_resp/1` restructured to parse the accumulated buffer FIRST and only
   recv on `:partial` (was: recv-first, so a recv returning two concatenated
   frames or a partial tail desynced the per-socket frame buffer). Stashed
   leftover per socket via `Process.get/put({:resp_buf, sock})`.

Response parsing re-checked against the court reference: the F4 tests in
kafka_wire_test.exs already read the ListOffsets v0 block in the correct order
(partition i32 BEFORE error_code i16) — no parse change needed.

## Run output (embedded)

```
$ MIX_BUILD_ROOT=_build-bkkwt mix test test/internal/kafka_wire_test.exs
04:48:13.574 error[] [kafka] CRASH-ONLY kill: {:corrupt_batch, :crc_mismatch}; connection closed
04:48:13.575 error[] [kafka] CRASH-ONLY kill: {:unsupported_version, 0, 9}; connection closed
.  (…expected negative-probe kills…)
04:48:14.576 info[] [kafka] replayed 6 batch(es) from sealed journal under /Users/sac/.cache/tmp/smalt-kafka-journal-test-516797354
Finished in 42.4 seconds
Result: 9 passed
```

(The PolicyViolationError traceback mid-run is the EXPECTED sieve-refusal test
raise — client exits nonzero by design, not a flake.)

## PolicyViolationError(44) flake check (owner AZ-1, surface untouched)

6/6 additional plain-produce probe runs green (real self-booted listener,
MIX_ENV=test ephemeral ports):

```
BK-KWT probe reruns: [{1, 0, true}, {2, 0, true}, {3, 0, true}, {4, 0, true},
{5, 0, true}, {6, 0, true}]
BK-KWT probe reruns: 6 runs, 0 failed
```

Verdict: **unreproduced-in-6** (8 produce calls total across runs, 0
spontaneous 44s). Flag stands as-is for AZ-1; not typed as a defect here.

## Regression: kafka_exp4 court — transient shared-lib freeze, disclosed

First court run mid-wave failed 4/6 (`{:error, :closed}` + listener
`:malformed_request_header`): another lane's IN-FLIGHT `conn.ex` edit had
moved the catch-all `defp dispatch(_req, state)` clause ABOVE the specific
classic-header clause, so every wire request hit the catch-all kill. By the
compile-freeze SLA the owner repaired the clause order in-place minutes later
(no fix applied by this lane — verified on re-read). Post-repair:

```
$ MIX_BUILD_ROOT=_build-bkkwt mix test test/internal/kafka_exp4_court_test.exs
Result: 6 passed
```

and kafka_wire_test.exs re-confirmed 9 passed after the repair.

## Replay

```bash
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bkkwt mix test test/internal/kafka_wire_test.exs      # 9 passed
MIX_BUILD_ROOT=_build-bkkwt mix test test/internal/kafka_exp4_court_test.exs # 6 passed
```
