# i29 — KQL fuzz determinism (cosmos_test.exs:1055)

**Standing: PASS** · Context: slice(x5) · 2026-10-18

## Defect

`test/data_plane/cosmos_test.exs` "unicode and random binaries terminate quickly"
used `:crypto.strong_rand_bytes(:rand.uniform(128))` as fuzz input and asserted
`{:error, _}` unconditionally. A random binary can lex to a token stream
starting with `{:word, "|"}` (leading byte 0x7C) and parse to zero stages —
or be whitespace-only — yielding the lawful `{:ok, []}`. Seed lottery:
solo bisect was 126/0; the failing face appears only when ExUnit's random
seed orders/hits the adversarial input.

## Fix (deterministic-or-typed, no assertion weakened)

Constraint of the fuzz space to CLASSIFIED inputs; expectation derived from
input properties:

- `lib/smalt/data_plane/kql.ex` `parse_stages/2` accepts a token stream only
  when its first token is `{:word, "|"}`; any other first token (word /
  string / paren / comma) is a typed `{:parse, _}` error.
- A whitespace-only binary lexes to zero tokens → zero stages → lawful
  `{:ok, []}` on empty rows.

New private helper `classified_error_fuzz_input/0` resamples any random binary whose first byte is whitespace (token stream may be
empty) or `|` (parse unclassified), so every emitted input is guaranteed
`{:error, {:parse, _}}` regardless of seed. Added the classified
whitespace-only `{:ok, []}` face as a deterministic assertion. The typed-error
assertion was TIGHTENED to `{:error, {:parse, _}}` (was `match?({:error, _})`).
No seed pin needed — expectation is provable from the lexer/parser contract.

## Verify

`MIX_BUILD_ROOT=_build-ft-kql mix test test/data_plane/cosmos_test.exs` x5
consecutive runs (fresh ExUnit seed each run):

```
126 tests, 0 failures (2 excluded)
126 tests, 0 failures (2 excluded)
126 tests, 0 failures (2 excluded)
126 tests, 0 failures (2 excluded)
126 tests, 0 failures (2 excluded)
```

5/5 green.

## Machine

`just bench-machine`: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Files

- `/Users/sac/smalt/test/data_plane/cosmos_test.exs` — fuzz generator now
  classified; whitespace-only lawful face added; helper at EOF (line ~3122).

Falsifier: any seed under which the fuzz test fails. 5 consecutive
independent-seed runs returned 0 failures.
