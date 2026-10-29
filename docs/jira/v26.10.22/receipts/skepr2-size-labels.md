# Receipt: SKEP-R2 — BK-SKEP F2 size-label normalization (frame_decoder)

**Standing**: ALIVE
**Context**: solo
**Lane**: SKEP-R2, repo /Users/sac/smalt, MIX_BUILD_ROOT=_build-skepr2
**Subject**: `lib/smalt/messaging/amqp10/frame_decoder.ex`,
court `test/internal/wire_exp4_court_test.exs`

## Change

Closes BK-SKEP finding F2 (`bkskep-amqp10-skeptic.md` §B.F2, left as
"cosmetic, ~10 fallback clauses" by SKEP-R1). Structurally impossible declared
sizes — the declared size cannot be valid for its constructor regardless of
how many bytes follow — were answered `{:error, :truncated_frame}` by the
fallback clauses. The real fault is the size, not the input length. New
fallback clauses ahead of each truncation fallback:

| constructor | impossible class | now answers |
|---|---|---|
| 0xC0 / 0xC1 | size = 0 (count byte needs 1) | `{:error, :bad_element}` |
| 0xD0 / 0xD1 | size < 4 (count needs 4 bytes) | `{:error, :bad_element}` |
| 0xB0 / 0xB1 / 0xB3 | size > @max_frame_size (e.g. 0xFFFFFFFF) | `{:error, :bad_element}` |

Genuine short input (lawful declared size, missing payload bytes) keeps
`{:error, :truncated_frame}` — only the impossible-size label moved. Label
follows the module's committed convention (SKEP-R1 used `:bad_element`; the
module has no `:bad_size` reason). Typed-never-raise behavior preserved:
no raise path touched, only labels.

## Court

Extended `wire_exp4_court_test.exs` with two tests (9 → 11):

- "BK-SKEP F2: structurally impossible declared sizes answer bad_element,
  not truncated_frame" — 7 legs: C0 size=0, D0 size=2, B0/B1/B3 0xFFFFFFFF,
  C1 size=0, D1 size=2.
- "BK-SKEP F2 non-vacuity: genuine short input still answers truncated_frame"
  — B0 200-vs-3-bytes, D0 declared 20 short, C0 declared 10 short.

## Embedded court output

```
$ MIX_BUILD_ROOT=_build-skepr2 mix test test/internal/wire_exp4_court_test.exs
Running ExUnit with seed: 340237, max_cases: 32
...........
Finished in 0.05 seconds (0.05s async, 0.00s sync)
Result: 11 passed

$ MIX_BUILD_ROOT=_build-skepr2 mix test test/integration/amqp10_crash_only_court_test.exs
Finished in 25.1 seconds (0.00s async, 25.1s sync)
Result: 8 passed
```

## Non-vacuity (revert-guard)

Pre-fix decoder (git show HEAD:...) compiled standalone to /tmp/skepr2
(EXPL-4/BK-SKEP precedent, no tree writes) and probed on the same bytes:

```
PRE-FIX C0 size=0: {:error, :truncated_frame}
PRE-FIX D0 size=2: {:error, :truncated_frame}
PRE-FIX B0 0xFFFFFFFF: {:error, :truncated_frame}
```

All three flip to `:bad_element` post-fix and the new court legs assert the
corrected labels — the court fails against the pre-fix module.

## Regression

amqp10_crash_only 8/8 green (above). wire_exp4 9 pre-existing legs stay green
(11/11 includes them).
