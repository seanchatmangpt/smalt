# BK-FRM — Frame.encode op-range guard + Frame.decode reserved-zero law (EXPL8-R typed residue)

Standing: **ALIVE**
Context: solo
Date: 2026-10-22
Lane: BK-FRM
Toolchain: asdf elixir 1.20.4-otp-29, `MIX_BUILD_ROOT=_build-bkfrm`

Closes the two EXPL8-R typed-residue findings on `lib/smalt/sync/frame.ex`
(the ATH-1 wire frame codec, server mirror of `workspace/lib/engine/codec.ts`).

## Disposition (read-before-change, per lane order)

- **Client codec** (`workspace/lib/engine/codec.ts`): the browser is the
  frame SENDER; its encoder always writes zero reserved (codec.ts:90
  "bytes[37..41) stay zero") and its `decodeFrame` does not inspect the pad.
  The SERVER is the decode side. No existing court pins pad-TOLERANCE —
  the ath1 court pins `pad == 0` on the ENCODE wire (ath1 court
  "frame encode/decode round-trips" leg) — so the typed-refusal branch
  applies, not the doc-only branch.
- **Codec law** (SYNC-RECEIPT-CHAIN.md §1): 41-byte header, reserved = zero
  pad; server mirror decodes the same layout with typed refusals never a
  raise.
- **KD-165 context** (via `bk109-kd165-pointer.md` → canonical register):
  the sync chain's typed-refusal discipline exists so verification
  failures surface as values; a silently-accepted nonzero pad would be a
  same-class widening (malformed header accepted as data).

## Changes — lib/smalt/sync/frame.ex

1. **encode/1 op-range guard**: `:op` must be an integer in `0..255`
   (the 41-byte header's opCode is a single byte; the encode @doc already
   documented 0..255). Out-of-range / non-integer → typed `ArgumentError`
   at the boundary (E8-T7 precedent: typed error at the boundary, control
   legs prove boundary values 0 and 255 and the absent-op default 0 still
   encode). Previously `<<op::8>>` raised mid-pattern (or truncated) on
   out-of-range op with no contract-consistent refusal.
2. **decode reserved-zero law**: a nonzero 4-byte reserved pad (offset
   37..40) is now a typed `{:error, {:bad_frame, "BAD_RESERVED"}}` —
   same value-shaped refusal family as SHORT_FRAME / BAD_MAGIC / BAD_LEN.
   Moduledoc failure table updated. Zero pad decodes unchanged.
3. Doc: moduledoc failure table gains the `BAD_RESERVED` row.

## Court legs added (extend, not break)

`test/internal/ath1_batch_frame_receiver_court_test.exs` (codec pure legs):

- "EXPL8-R residue: out-of-range :op is a typed refusal at the encode
  boundary" — op 256 / -1 / :read each raise ArgumentError
  (~r/:op must be an integer in 0\.\.255/); op 0 / 255 / absent-default
  still encode at 42 bytes.
- "EXPL8-R residue: nonzero reserved pad is a typed BAD_RESERVED decode
  refusal" — a valid frame with byte 40 flipped to 0x01 refuses
  `{:error, {:bad_frame, "BAD_RESERVED"}}`; the unmodified frame still
  decodes {:ok, ...} with crc_ok true.

## Verification (embedded court output)

```
$ MIX_BUILD_ROOT=_build-bkfrm mix test test/internal/ath1_batch_frame_receiver_court_test.exs
Result: 13 passed            (was 11 + 2 new EXPL8-R legs)
EXIT=0

$ node workspace/scripts/codec-court.mjs
# codec court verdict: PASS (0 failure(s))
CODEC_EXIT=0

$ node workspace/scripts/sync-e2e-court.mjs
SUMMARY: 9/9 PASS, 0 FAIL
EXIT=0

$ node workspace/scripts/exp1c-journal-court.mjs
SUMMARY: 16/16 PASS, 0 FAIL
EXIT=0
```

## Regression posture / lane-external note

`test/internal/internal_tier_census_test.exs` currently exits 2 with 3
failures, ALL citing other lanes' in-flight files
(`bkmaap6_nonce_bounds_court_test.exs` status-literal asserts,
`expl11r3_court_test.exs` Jason tokens + population drift). Pre-existing
lane-external churn (both files modified in the shared tree per git status);
no BK-FRM file is cited in any violation. ath1 remains census-registered —
the court was extended, not renamed.

## Falsifier

An out-of-range op that still encodes, or a nonzero-pad frame that still
decodes {:ok, ...}, would refute the repairs; neither observed (both new
court legs assert the refusals directly over the real codec, no mocks).

## Standing boundary

Pure codec surface; wire bytes for well-formed frames are unchanged
(bit-identical encode for 0<=op<=255, zero pad), so no cross-lane sync
surface churn. Receipt documents inspection-time state of the shared tree.
