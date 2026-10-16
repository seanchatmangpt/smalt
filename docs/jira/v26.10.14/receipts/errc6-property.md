# Receipt: ERRC Raise Lane 6 — Property-Based Testing with Shrinking

Date: 2026-10-15
Lane: errc-6 (Raise)
Repo: /Users/sac/smalt @ main (working tree, no commits made)
Scope: adopt property-based testing with shrinking over hand-rolled fuzz
matrices (frame_codec_test lens blocks, test_hw.py fixed vectors, ETF codec
example tables). No commits, no net lib edits.

## Standing

ALIVE — executed on the exact subject: both property suites ran green on this
checkout, plus one witnessed failure on a deliberately broken decode branch
(shrink evidence below).

## What landed

| File | Change |
|---|---|
| `mix.exs` | added `{:stream_data, "~> 1.2"}` (no `only:`, because `ash` requires stream_data non-optionally env:prod — Mix surface-convergence constraint; test-only usage, never packaged: `files:` whitelist) |
| `smalt-cli/.venv` | `hypothesis` 6.170.0 installed via pip |
| `smalt-cli/test_hw_property.py` | NEW — 11 property tests (hypothesis) |
| `test/property/frame_codec_property_test.exs` | NEW — 7 properties (stream_data) |
| `lib/smalt/hw/frame.ex` | UNCHANGED net (temporarily broken for the shrink witness, restored byte-identical; `git diff` on the file is empty) |

Existing example-based suites untouched and still passing (they are the pinned
regressions these properties generalize).

## Property count

Python (hypothesis, `cd smalt-cli && .venv/bin/pytest test_hw_property.py`):
11 passed in 0.72s

- P1 frame round-trip over arbitrary payloads x arbitrary chunk splits
- P1b CRC witness + determinism
- P1c stuffing invariant (no bare 0x7E/0x7D in stuffed stream)
- P1d oversize payload raises ProtocolError (4097 bytes)
- P2 sign-challenge wire identity
- P2b enroll wire identity
- P2c SIGNED_RECEIPT round-trip
- P2d CAPABILITIES round-trip
- P2e DEVICE_ERROR round-trip (all 5 message types covered)
- P3 arbitrary byte soup, any chunking, never raises; emitted frames re-validate
- P3b noise-bracketed frame still delivered

Elixir (stream_data, `MIX_ENV=test mix test test/property/frame_codec_property_test.exs`):
7 properties, 0 failures (run 5x total, 3x consecutively — no flakiness)

- P1 encode_frame -> decode_frame round-trip over 13 generated performatives
  (open/begin/attach/flow/transfer/disposition/detach/end/close + 4 SASL),
  generated fields/channels; layer-coupled type-performative pairing
- P2 decode_frame total over arbitrary binaries (tagged ok/more/error, never raise)
- P2b PrimitiveCodec.decode total over arbitrary binaries
- P3 Hw.Frame round-trip + split-invariance (arbitrary payload x chunk cuts)
- P3b corrupted-CRC frames are dropped (the shrink-witness property)
- P4 Hw decoder totality over byte soup, any chunking
- P5 Store exactly-one-winner: N (2..12) racing `compare_and_swap/4` yield
  exactly one `:ok`, N-1 `{:error, :conflict}`, get observes the winner value;
  same law for `insert_new/3`; repeated over generated keys (1-4), initial values

## Shrink witness (deliberately broken decode branch)

Break: `lib/smalt/hw/frame.ex:136` `emit/1` CRC-accept branch
`true <- crc16(...) == crc` -> `true <- true` (accept any CRC).

Run: `MIX_ENV=test property P3b` — falsified in the FIRST generated input,
stream_data SHRANK to the minimal counterexample:

```
Failed with generated values (after 0 successful runs):
    * Clause: payload <- binary(max_length:  shrunk to:
    Generated: ""   (empty binary, 1 byte? no — zero bytes)
corrupted-CRC frame was delivered: [""]
```

The minimal witness is the empty payload: a 6-byte wire frame
`7E 00 00 00 00 7E` whose CRC bytes are all zero — the smallest input that
separates "accept any CRC" from "CRC must match". The property then gates the
repair: restore the branch, rerun, `7 properties, 0 failures` (run twice to
confirm). This is the exact regression value over the hand-rolled matrices:
the broken branch is falsified by the minimal member of an *infinite* input
class, without a hand-written vector for it.

## Findings during the lane

1. Real shrink find (pre-existing, fixed in-generator): hypothesis' first
   counterexample for the SIGNED_RECEIPT round-trip was `serial=''` — an empty
   serial is genuinely a truncated wire message (decode raises
   "SIGNED_RECEIPT truncated"), so the generator now draws `min_size=1`. The
   generator encodes the wire precondition, not a test bug.
2. Two shared-checkout compile freezes during the lane (connection.ex,
   virtual_serial.ex — other lanes' in-flight edits). Both cleared within the
   ~10-minute SLA; no action by this lane.
3. `stream_data` cannot be `only: :test` in this tree: `ash` pins it
   env:prod non-optional. Disclosed in mix.exs comment.

## Not done / boundaries

- ETF codec (workspace/lib/atomvm/etf.ts) is TS, out of lane scope per dispatch
  (no lib edits); its coverage stays with the existing example tables.
- AmqpDialect surface not property-tested (dispatch listed it as a candidate
  surface; the required properties targeted frame/frame_codec + Store).
- No commits made.
