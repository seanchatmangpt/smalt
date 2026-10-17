# r224 — frame_codec property burst: diagnosis receipt

Standing: **FLAKE_SOLO** (solo-green ×2; not a codec defect — see classification)
Date: 2026-10-17
Lane: diagnosis lane 663 (`MIX_BUILD_ROOT=_build-lane663`), read-only on `lib/`
Milestone: v26.10.16

## Subject

- `test/property/frame_codec_property_test.exs` — all 7 properties (P1, P2, P2b, P3, P3b, P4, P5)
- `lib/smalt/messaging/amqp/frame_codec.ex` sha256 `e2b9690fde7a96f536f0d3ce363b23cdb539d5c2b8582a6689daa6eb87144f0b`
- `lib/smalt/messaging/amqp/primitive_codec.ex` sha256 `5e5481bac74c721b499d4e95044b26c0dca7774bd88cdfc6afdf2e2f54136e63`
- `lib/smalt/hw/frame.ex` sha256 `74c5a673a1df570a918e9aa5743985431e2420a7caec7942623fb8ad1473f871`
- `git status --short lib/ test/property/` → empty (codec + property sources byte-identical to HEAD)

## Trigger evidence: court-x2 wrap run 26

Log: `tmp/court-x2-wrap-run26.log`

- Run 1 exit 2 — `1 doctest, 7 properties, 2435 tests, 224 failures (43 excluded)`,
  wall 328.6s (23.8s async / 304.8s sync), over the FULL offline suite.
- All 7 FrameCodec properties are in run 1's failing set (log lines 67-73).
- Run 2 (fresh `just court`, no reuse): failing tests — `(none)` — the identical
  tree is green on re-run with no intervening edit (`git status` clean between runs;
  `1,224c1` diff, run1 224 → run2 0).
- The run-1 burst is NOT frame-codec-local: it spans `auth_enforce`, `pplan`, `spc_drift`,
  `ash_extension`, `mcp_wire`, `sb_rules`, `arm_wire` — a mass-failure burst across
  unrelated subsystems. Sampled failure bodies in the log tail (`auth_enforce_test.exs:484`,
  `auth_enforce_test.exs:1430`) are cross-seat auth verification misses — the same
  mass-burst signature seen in prior load/teardown artifacts.

## Solo reproduction (this lane, _build-lane663)

`MIX_BUILD_ROOT=_build-lane663 mix test test/property/frame_codec_property_test.exs`

Run 1:
```
Running ExUnit with seed: 339610, max_cases: 32
Excluding tags: [:amqp_wire]
.......
Finished in 0.2 seconds (0.00s async, 0.2s sync)
7 properties, 0 failures
```

Run 2:
```
Running ExUnit with seeds 381644, max_cases: 32   (recorded: "Running ExUnit with seed: 381644, max_cases: 32")
Excluding tags: [:amqp_wire]
.......
Finished in 0.2 seconds (0.0s async, 0.2s sync)
7 properties, 0 failures
```

Both exit 0.

## Classification: FLAKE_SOLO-family (load/parallelism artifact, court-environment)

- Green solo ×2 with fresh random seeds (339610, 381644).
- Identical tree flips 224-fail → 0-fail between court run 1 and run 2 with zero
  source change; failure set spans unrelated subsystems (auth/pplan/spc/ash/mcp).
- No shrinking counterexample exists to preserve: the court log retained only the
  failing-test name list for FrameCodec (tail-cropped bodies); solo reruns of the
  file cannot reproduce under fresh seeds.
- Codec sources byte-identical to HEAD during both solo runs and the court wrap —
  no `lib/` edit in this window, so the burst is not a mid-run codec mutation.

## Court run-2 exit-1 note (adjacent, pre-existing)

Court wrap run 2 exited 1 on missing hex deps (`deps/` absent at run 2 start —
swept between run 1 and run 2, not by this lane; lane 663 had to `mix deps.get`
fresh). Run 2's test verdict itself was green: failing tests `(none)`. This is an
environment receipt for the next window: re-verify `deps/` presence before
attributing exit codes.

## Falsifier / next window

Claim to kill: "the FrameCodec properties are solo-unstable."
Kill it with: `MIX_BUILD_ROOT=<root> mix test test/property/frame_codec_property_test.exs`
repeated ≥3 times with fresh seeds; any shrunk counterexample (seed + generated
frame) reproducing solo promotes this to a REAL codec finding and re-opens r224.
Until then r224 is classified FLAKE_SOLO and the 224-failure burst is attributed
to court-environment load, pending a run that reproduces solo.
