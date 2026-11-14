# smalt-14-azure-parity-receipt-and-functions-row

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/docs/azure-parity/AZ2.md` (Standing: PARTIAL) states "no test executed this lane";
HAVE-TESTED means file presence only, pass state UNVERIFIED. It also records that
`/Users/sac/smalt/docs/WIRE_PARITY.md` has no Functions row and `/Users/sac/smalt/docs/verification`
holds only ocel with no
dated gate receipt. `/Users/sac/smalt/test/azure` does not exist; Azure pins live in
`/Users/sac/smalt/test/integration`,
`/Users/sac/smalt/test/internal`, `/Users/sac/smalt/test/data_plane`.
`/Users/sac/smalt/lib/smalt/azure` holds only `kv_certificates.ex` and
`log_analytics.ex`.

## Acceptance

- Command: `mix test /Users/sac/smalt/test/data_plane /Users/sac/smalt/test/internal` from
  /Users/sac/smalt; expected: 0 failures,
  result (command, exit, count) recorded in `/Users/sac/smalt/docs/azure-parity/AZ2.md`.
- `grep -n "Functions" /Users/sac/smalt/docs/WIRE_PARITY.md` returns a row with
  ALIVE/PARTIAL/PLANNED status.
- `/Users/sac/smalt/docs/azure-parity/AZ2-matrix.json` cells cite a run result, not file presence.

## Falsifier

AZ2.md still says "pass state NOT re-run", or the Functions grep returns nothing.

## Owned files

- /Users/sac/smalt/docs/azure-parity/AZ2.md, /Users/sac/smalt/docs/azure-parity/AZ2-matrix.json,
  /Users/sac/smalt/docs/azure-parity/SM3.md
- /Users/sac/smalt/docs/WIRE_PARITY.md (Functions row only)

## Depends-on

smalt-15 (shares WIRE_PARITY.md edits; serialize).

## Size

M

## References (path : LOC)

- /Users/sac/smalt/docs/azure-parity/AZ2.md : 17 lines
- /Users/sac/smalt/docs/azure-parity/AZ2-matrix.json : 9 lines
- /Users/sac/smalt/docs/azure-parity/SM3.md : 12 lines
- /Users/sac/smalt/docs/WIRE_PARITY.md : 296 lines
- /Users/sac/smalt/docs/verification/ : 3 files, 360 lines total
- /Users/sac/smalt/lib/smalt/azure/ : 2 files, 170 lines total
- /Users/sac/smalt/lib/smalt/azure/kv_certificates.ex : 131 lines
- /Users/sac/smalt/lib/smalt/azure/log_analytics.ex : 39 lines
- /Users/sac/smalt/test/data_plane/ : 12 files, 1546 lines total
- /Users/sac/smalt/test/internal/ : 114 files, 22781 lines total
- /Users/sac/smalt/test/integration/ : 165 files, 42401 lines total

## Result

Standing: UNVERIFIED
Functions row already at /Users/sac/smalt/docs/WIRE_PARITY.md:175 (PARTIAL). AZ2.md (+6 LOC) reworded to
drop "NOT re-run" and gained a "Run result" slot (PENDING); matrix pass_state unchanged (UNVERIFIED).
No test run (forbidden). Acceptance: cd /Users/sac/smalt && mix test test/data_plane test/internal;
then fill AZ2.md Run result and set AZ2-matrix.json pass_state/pass_source from the output.
