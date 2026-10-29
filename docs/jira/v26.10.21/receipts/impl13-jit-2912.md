# IMPL-13: JIT multi-segment binary matching on OTP 29.1.2 (pinned release re-adjudication)

Context: solo

**Standing:** REFUTED (stands)

## Claim

Prior bench (622 vs 635 ms, ~2% parity) ran on 29.1.1. Re-run on the pinned
29.1.2 (asdf, explicit PATH) vs host 28.3.1, plus a real-AMQP leg through
`Smalt.Amqp.FrameCodec`.

## Toolchains (verified before each run)

- OTP 29.1.2: `PATH=/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin:/Users/sac/.asdf/installs/erlang/29.1.2/bin:$PATH`
  → `otp=29 erts=17.1.1`
- OTP 28.3.1 (host): `/Users/sac/.erlmcp/otp-28.3.1` + asdf elixir 1.20.3-otp-28
  → `otp=28 erts=16.2`

## Leg 1 — mixed-endian binary segment matching (`p2_binbench.escript`, unchanged)

1M map32-style decodes, min-of-5, reductions via `erlang:statistics(reductions)`:

| toolchain | runs (ms) | min | reductions |
|---|---|---|---|
| OTP 29.1.2 | 712, 612, 651, 639, 628 | **612** | 131,001,116 (every run) |
| OTP 28.3.1 | 695, 719, 708, 706, 721 | **695** | 131,001,116/226 (every run) |

Wall delta min-vs-min: **11.9% in favor of 29.1.2**. Reduction counts
byte-identical — the JIT change affects codegen speed, not work performed.
No transformation regression: 29.1.2 is not slower on 28.

## Leg 2 — real AMQP transfer frames (`tmp/otp29_probes/impl13_amqp_framebench.exs`)

One 1582-byte transfer frame (header + properties + application_properties +
1400-byte body_data, Service-Bus-dialect sections as FrameCodec actually
encodes them), built with `encode_frame/3` and decoded 100k times via
`decode_frame/1`, pure module calls (no app boot), best-of-5 rounds per run,
3 runs per toolchain:

| toolchain | best run (ms / us/frame / reds/frame) | all runs |
|---|---|---|
| OTP 29.1.2 | **103 ms / 1.03 us / 254.3** | 103, 104, 105 |
| OTP 28.3.1 | **106 ms / 1.06 us / 254.3** | 106, 107, 109 |

Delta: **2.8% wall, 0.0% reductions** (254.3 both). No ≥30% divergence on the
real wire-codec surface either.

## Verdict

The ≥30% flip threshold is not met on either leg on the pinned 29.1.2.
**REFUTED stands** — the JIT multi-segment binary-matching claim shows no
material divergence between 28.3.1 and 29.1.2 (max observed 11.9% wall, same
reduction counts, and the direction favors 29.1.2).

## Disclosures

- Concurrent-lane compile freeze: `lib/smalt/json_compat.ex` (in-flight edit,
  mtime 13:43 during this lane's run) does not parse under Elixir 1.20.x,
  blocking `mix compile` on both build roots. No lib/ changes were made; both
  legs bypassed mix with direct `-pa` on already-compiled beams
  (`_build-otp29p` for 29.1.2, host `_build/dev` for 28.3.1 — FrameCodec beam
  OTP-28-native). FrameCodec itself was unaffected by the frozen file.
- Host elixir 1.19.5 is rejected by the repo's `~> 1.20` pin; the 28.3.1 leg
  used asdf elixir 1.20.3-otp-28 driving erlmcp erl 28.3.1.

## Machine

`just bench-machine`: {"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}

## Receipt

- Commands: escript p2_binbench.escript x5 per toolchain;
  `elixir -pa <ebin> tmp/otp29_probes/impl13_amqp_framebench.exs` x3 per
  toolchain (exit 0 all runs)
- Scripts: `/Users/sac/smalt/tmp/otp29_probes/p2_binbench.escript` (untouched),
  `/Users/sac/smalt/tmp/otp29_probes/impl13_amqp_framebench.exs` (new, tmp/ only)
- lib/ changes: none
