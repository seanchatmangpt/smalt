# L41 — bin-opt gate defect: `stage3_fields/2` context-reuse defeat (frame.ex, not worker.ex)

Standing: PASS

## Finding

`just bin-opt` exited 1 on 2 scoped FAIL-class warnings naming
`stage3_fields/2`. The dispatch named `lib/smalt/aoq/worker.ex`, but
`stage3_fields/2` lives in `lib/smalt/aoq/frame.ex` — the decode path
(`stage1_wire_shape` → `stage2 CRC` → `stage3_fields`) is frame.ex code;
worker.ex contains no stage3_fields. Fixed the actual defect site.

## Root cause

Stage 1 matched only wire shape (`prefix::binary-size(32), crc, 0::224,
payload`), then handed the ORIGINAL wire (`bin`) to `stage3_fields/2`
for a full header re-match. A wire re-match behind a CRC `if` cannot
reuse the stage 1 match context, so OTP 29 `bin_opt_info` emitted:

- `NOT OPTIMIZED: binary is used in call to stage3_fields/2 which does not begin with a suitable binary match`
- `BINARY CREATED: binary is used in call to stage3_fields/2 which doesn't support context reuse`

## Fix (lib/smalt/aoq/frame.ex, only file changed)

1. Stage 1 now extracts every header field in its single context-reused
   match — magic as `binary-size(4)`, the rest as integer segments — with
   NO field literals and NO field checks in the stage 1 guard, so every
   flip in bytes 0..31 reaches the stage 2 CRC gate as `:bad_crc`
   (court law: bytes 0..31 flips are CRC-class, bytes 36..63 zeros stay
   literal in the pattern → `:bad_header`).
2. CRC still computed over `:erlang.binary_part(bin, 0, 32)` (no
   re-slice match).
3. `stage3_fields/9` validates fields via head GUARDS on the extracted
   integers (magic/version/reserved-zeros/payload_len/known_flags),
   AFTER the CRC gate. Its head begins with `<<_::binary>> = payload` —
   the bin_opt law found by experiment (T2/T3/T4 scratch courts): a
   callee receiving a sub-binary must BEGIN its head with a binary
   match or the caller materializes the binary. The 32-byte field
   region sits BEFORE the CRC on the wire, so no context can be chained
   into a field match; integer extraction + guard validation is the
   lawful shape.
4. `admit_tables/6` got the same head-begin binary match (`<<_::binary>>
   = payload`) — the warning chained there once stage3_fields was fixed.

Wire semantics byte-identical: same error taxonomy and ordering
(`:short_frame` → shape `:bad_header` (incl. 36..63 zeros) → `:bad_crc`
→ field `:bad_header` → unknown type/epoch).

## Gate verdicts

- `MIX_BUILD_ROOT=_build-lane41 just bin-opt` → exit 0,
  `SUMMARY scoped_fail=0 scoped_benign=8 scoped_other=22`,
  "bin_opt gate: PASS (zero scoped FAIL-class warnings)"
- `bash scripts/shim_court/bin_opt_gate_court.sh` → exit 0, PASS,
  non-vacuous (BEFORE old-signature, AFTER new-outcome, restore
  sha256 byte-exact)
- `MIX_BUILD_ROOT=_build-lane41 mix test test/courts/aoq_framing_court.exs
  test/smalt/aoq/supervisor_test.exs test/smalt/hw/frame_test.exs` →
  37 passed, 0 failures (framing court 24, supervisor 7, frame 6)

Intermediate red: first restructure put the 18..23 reserved-zeros check
in the stage 1 guard — flipped bytes there returned `:bad_header`
instead of `:bad_crc`; framing court byte-flip test caught it, guard
moved into the stage 3 (post-CRC) head. Also one silent python-replace
no-op was caught by re-reading the file (gate stayed red with an 8-arg
call against a 9-arg head).

## Standing

PASS — all three gates green on the final file state, receipt cites
commands + exits above.
