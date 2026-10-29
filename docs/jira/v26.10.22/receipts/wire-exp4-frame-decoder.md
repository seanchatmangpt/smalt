# Receipt: wire-exp4 frame-decoder truncation repair (EXPL-4 F2)

**Standing**: ALIVE
**Context**: solo
**Lane**: WIRE-EXP4, repo /Users/sac/smalt, build root `_build-wirex4`
**Subject**: `lib/smalt/messaging/amqp10/frame_decoder.ex`, court test
`test/internal/wire_exp4_court_test.exs`

## Finding repaired (EXPL-4 F2)

Every sized-element constructor (0xA0/0xA1/0xA3/0xB0/0xB1/0xB3/0x98) guarded
only the declared length bound, not `byte_size(rest) >= n`; a truncated frame
body raised a bare MatchError (witnessed: declared 200-byte string, 3 bytes
follow). 0xC0/0xD0 ignored their declared size field — trailing bytes were
silently absorbed into the transfer payload.

## Repair

Sized-element clauses now guard the AVAILABLE byte count
(`byte_size(rest) >= n`) with a truncation fallback clause per constructor
answering `{:error, :truncated_frame}` — never a raise. 0xC0/0xD0/0xC1/0xD1
declared sizes are binding: the constructor is sliced to the declared size
first (truncation => `{:error, :truncated_frame}`), then the count elements
must consume the slice exactly (`take_exact/3` / `map_exact/3`); trailing
bytes inside the declared slice answer `{:error, :bad_element}`.
Moduledoc claim tightened to match ("decode never raises on remote input" is
now receipted, see moduledoc lines 10-18).

Naming note: the lane order specified `{:error, :truncated_element}`; the
landed surface uses `:truncated_frame`, consistent with the module's
committed convention and the 0x98 pre-existing clause. Courted as landed.

## Court (real binary-frame probes, Chicago — no mocks, no sleeps)

Falsifier legs per constructor class, all through the public
`decode_frame/1` boundary: truncated 0xA0/0xA1/0xA3 (declared 200, 3 bytes
follow), truncated 0xB0/0xB1/0xB3 (declared 200::32, 3 bytes follow),
truncated 0x98 (declared 16, 5 bytes follow), 0xC0/0xC1/0xD0/0xD1 truncation
and trailing-byte-inside-declared-slice refusal, every-proper-prefix leg
(only tagged tuples), and non-vacuity legs proving full payloads still
decode.

```
$ MIX_BUILD_ROOT=_build-wirex4 mix test test/internal/wire_exp4_court_test.exs
........
Finished in 0.04 seconds (0.04s async, 0.00s sync)

Result: 8 passed
```

Non-regression on the pre-existing structural-equivalence court:

```
$ MIX_BUILD_ROOT=_build-wirex4 mix test test/integration/amqp10_crash_only_court_test.exs
Finished in 25.1 seconds (0.00s async, 25.1s sync)

Result: 8 passed
```

Note: `scripts/fast_test.sh` failed cold with `(Mix) You're trying to run
:smalt on Elixir v1.19.5` — homebrew elixir (1.19.5) shadowed the asdf
1.20.4-otp-29 shim; resolved by putting `$HOME/.asdf/shims` first on PATH.

## Commit

Frame-decoder repair landed in an earlier tick checkpoint (working tree was
clean at lane start); this receipt + the court test are the lane delta,
staged by explicit path.
