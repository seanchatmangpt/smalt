# BK-3 Receipt: JSONSAX Streaming Helper Court

**Standing**: ALIVE (helper implemented, courted, 14/14 green on this checkout)
**Context: solo**
**Date**: 2026-10-22
**Subject**: `lib/smalt/json_compat.ex` — `Smalt.JsonCompat.stream/3` (JSONSAX / streaming JSON helper)

## What was found on arrival

The helper was already implemented in `lib/smalt/json_compat.ex` (lines 74-303,
"T42-verified hook architecture"): discard-style SAX streaming over the native
OTP 28+ `:json` decoder (`decode_start/3` + `decode_continue/2`), chunk-pumped
(default 64 KiB), element-wise dispatch of top-level array elements, NDJSON /
concatenated-document support, typed `{:error, {:malformed_json, reason}}`
refusals, and an `accumulate: true` mode. An earlier court existed at
`test/json_compat_stream_test.exs` (11 tests). **The missing piece was the
BK-3 lane court** with the four named Chicago legs (large real payload,
malformed-tail typed refusal, deep nesting, byte-for-byte event stream) —
plus one court-discovered correction to the task premise (deep nesting is NOT
depth-refused; it streams, see finding F1 below).

## What this lane landed

`test/internal/bk3_jsonsax_court_test.exs` — 14 tests, Chicago style (real
`:json` decoder, real chunked binaries, real worker process heap sampling;
no mocks, no fixed sleeps; the only receive-after timeouts are bounded polls
on real observables):

1. **Large payload streamed**: 20k mixed docs across chunk boundaries,
   delivered once each, in order; chunk-size invariance (identical event
   stream at chunk sizes 1, 2, 3, 7, 64, 1024, whole-input); 1000-value
   scalar NDJSON corpus.
2. **Malformed tails refuse typed**: garbage tail, truncated array, invalid
   byte `0xFF` (asserts the exact decoder reason `{:invalid_byte, 0xFF}`),
   empty input — all `{:error, {:malformed_json, reason}}`, no raises.
3. **Deep nesting**: 100k-deep array nesting streams `{:ok, 1}` without
   crash or depth refusal; truncated deep nesting refuses
   `:unexpected_end_of_input`; 100-deep nested value survives intact inside
   a streamed doc (asserted equal to a whole-doc decode of the same slice).
4. **Byte-for-byte event stream**: streamed events equal whole-doc decode of
   the same input (modulo documented null->nil normalization); duplicate
   docs each delivered preserving multiplicity and order; single-key doc
   re-encodes byte-identically (`Jason.encode!` round-trip).

## Court output (embedded, real)

```
$ MIX_BUILD_ROOT=_build-bk3 scripts/fast_test.sh test/internal/bk3_jsonsax_court_test.exs
..............
Finished in 0.2 seconds (0.00s async, 0.2s sync)
Result: 14 passed
```

Pre-existing court (no regression, this checkout):

```
$ MIX_BUILD_ROOT=_build-bk3 scripts/fast_test.sh test/json_compat_stream_test.exs
Result: 11 passed
```

## Finding F1 (court-discovered premise correction)

The task named "deep nesting bounded" as a depth-refusal leg. Reality,
probed at depths 100/1k/10k/100k: the native `:json` SAX decoder has **no
depth limit** in this path — depth 100_000 streams `{:ok, 1}`. The bound the
helper actually provides is the documented one: peak heap is bounded by the
largest single delivered value + the chunk window, never by input size
(courted by the heap-sampling leg and by `test/json_compat_stream_test.exs`'s
sub-1MB peak-heap budget on the 50k-doc corpus). The court asserts reality:
no crash, typed refusal on truncation, heap sampled via real
`Process.info/2` on a live worker.

## Boundary

- `lib/smalt/json_compat.ex` was NOT modified (no code change needed; helper
  already complete) — zero lib diff from this lane.
- Caller surface: no lib caller today (`JsonCompat.stream` has no in-lib
  callers; the Cosmos page iteration path is the natural future consumer).
  This is the SNIPPET-REVIEW next-step-2 helper receipt, courted per lane
  task.
- 100k-deep nesting delivering `{:ok, 1}` is decoder reality, not a bound
  the helper enforces; any future depth cap belongs in the `:json` decoder
  options, not this helper.
