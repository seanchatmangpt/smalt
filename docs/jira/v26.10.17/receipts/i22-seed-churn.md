# i22 — seed-order hardening: shacl_fuzz under shuffled seeds (churn harness)

- **Date**: 2026-10-18
- **Lane**: fix lane (seed-order hardening), `MIX_BUILD_ROOT=_build-ft-r12`, repo `/Users/sac/smalt`
- **Standing**: ALIVE (3/3 shuffled seeds green, post-fix file)
- **Context**: solo (seed-churn harness, x3 sequential runs)

Context: solo (seed-churn harness, 3 sequential single-file-pair runs)
- **Subject**: `test/corpus/shacl_fuzz.exs` — worst offender per poll receipts `i22-shacl-fuzz-fix.md` pointer (fix landed as `Smalt.Corpus.Helper.resilient_clear/0`, see `receipts/i22-fuzz-atom-fix.md`, `receipts/i22-corpus-seed-hardening.md`)

## Protocol

Poll per lane order: `i22-shacl-fuzz-fix.md` did not exist at dispatch; it
appeared (as `i22-fuzz-atom-fix.md` + `i22-corpus-seed-hardening.md`) during
the 60s x10 poll window, and `test/corpus/shacl_fuzz.exs` was modified in the
same window — so the POST-FIX file was used, as directed.

## Run matrix (real seeds, sequential, one build root)

Harness: the post-fix file depends on `Smalt.Corpus.Helper` (resilient_clear),
which `test/corpus_test.exs` loads via `Code.require_file` at module body —
`shacl_fuzz.exs` no longer runs standalone (`UndefinedFunctionError`
Smalt.Corpus.Helper.resilient_clear/0, exit 2 when run alone). The
CI-representative invocation therefore pairs it with `test/corpus_test.exs`:

```
MIX_BUILD_ROOT=_build-ft-r12 mix test test/corpus_test.exs test/corpus/shacl_fuzz.exs --seed <S>
```

| seed | exit | result | fuzz verdicts (deterministic sweep) |
|---|---|---| ExUnit line |
| 1   | 0 | 26 tests, 0 failures | 668 admitted / 214 typed_refusal / 118 parse_typed |
| 42  | 0 | 26 tests, 0 failures | 668 / 214 / 118 |
| 777 | 0 | 0 failures (26 tests) | 668 / 214 / 118 |

Seed-1 run tail:

```
[shacl-fuzz] verdicts: %{admitted: 668, typed_refusal: 214, parse_typed: 118}
.....................
Finished in 2.8 seconds (0.00s async, 2.8s sync)
26 tests, 0 failures
SEED1_EXIT=0
```

Seed-42 run tail:

```
..................
Finished in 2.4 seconds (0.00s async, 2.4s sync)
26 tests, 0 failures
SEED42_EXIT=0
```

Seed-777 run tail:

```
[shacl-fuzz] verdicts: %{admitted: 668, typed_refusal: 214, parse_typed: 118}
...................
Finished in 2.6 seconds (0.00s async, 2.6s sync)
26 tests, 0 failures
SEED777_EXIT=0
```

## Finding: standalone invocation is broken post-fix (compile-freeze class)

```
** (UndefinedFunctionError) function Smalt.Corpus.Helper.resilient_clear/0 is undefined
    (module Smalt.Corpus.Helper is not available)
    stacktrace: test/corpus/shacl_fuzz.exs:55
3 tests, 3 failures  (exit 2, standalone `mix test test/corpus/shacl_fuzz.exs --seed 1`)
```

`shacl_fuzz.exs` calls `Smalt.Corpus.Helper.resilient_clear/0` but the helper
is a plain `.exs` require'd only by `corpus_test.exs`. Any CI lane or dev
loop running the file directly gets 3/3 failures regardless of seed. Not a
seed-order face — a load-order face. Options (owner's call, not applied
here): (a) `Code.require_file("test/corpus/helper.exs")` guard at the top of
shacl_fuzz.exs if File.exists?, or (b) always pair with corpus_test.exs in
the runner.

## Verdict

Seed-robust: **3/3 shuffled seeds green** post-fix (seeds 1 / 42 / 777).
No seed-order face tripped; no further mutation of the same class applied.
The standalone-invocation breakage above is disclosed to the fix-lane owner
(compile-freeze disclosure rule) — the paired invocation is the lawful
runner until it is resolved.
