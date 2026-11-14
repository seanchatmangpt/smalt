# smalt-17 changelog and mix version for v26.11.14 release

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/mix.exs:4` pins `@version "26.10.31"` while this milestone is v26.11.14.
`/Users/sac/smalt/CHANGELOG.md`
has only an `[Unreleased]` section headed by "Azure-parity + KQL window (v26.10.28 lanes)";
the GCP and AWS emulator surfaces (`/Users/sac/smalt/lib/smalt/gcp`,
`/Users/sac/smalt/lib/smalt/aws`, 76 tests passing in
`/Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws` this session) have no entry.

## Acceptance

`grep -n '@version' /Users/sac/smalt/mix.exs` prints `26.11.14` and
`grep -n '^## \[26.11.14\]' /Users/sac/smalt/CHANGELOG.md` prints one line mentioning
GCP and AWS surfaces.

## Falsifier

/Users/sac/smalt/mix.exs version differs from the newest dated CHANGELOG heading, or the entry
claims a gate
result with no receipt path.

## Owned files

- /Users/sac/smalt/mix.exs (version line only)
- /Users/sac/smalt/CHANGELOG.md

## Depends-on

smalt-13, smalt-14, smalt-15 (entry cites their receipts, UNVERIFIED until they land).

## Size

S

## References (path : LOC)

- /Users/sac/smalt/mix.exs : 189 lines
- /Users/sac/smalt/CHANGELOG.md : 806 lines
- /Users/sac/smalt/lib/smalt/gcp/ : 17 files, 3579 lines total
- /Users/sac/smalt/lib/smalt/aws/ : 11 files, 2064 lines total
- /Users/sac/smalt/test/gcp/ : 9 files, 860 lines total
- /Users/sac/smalt/test/aws/ : 7 files, 522 lines total

## Result

Standing: UNVERIFIED (edits re-read, no execution)

- /Users/sac/smalt/mix.exs: line 4 version -> 26.11.14 (1 LOC)
- /Users/sac/smalt/CHANGELOG.md: new [26.11.14] section (+19 LOC)

Acceptance: grep -n '@version' /Users/sac/smalt/mix.exs; grep -n '^## \[26.11.14\]' /Users/sac/smalt/CHANGELOG.md
