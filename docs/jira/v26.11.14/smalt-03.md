# smalt-03 azure parity receipt and wire parity census pins

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/docs/azure-parity/AZ2.md` is Standing PARTIAL: HAVE-TESTED means file presence
only, no
test was run, no Functions row exists in `/Users/sac/smalt/docs/WIRE_PARITY.md`, and
`/Users/sac/smalt/docs/verification`
holds no dated gate receipt. WIRE_PARITY.md's KD1 path remap (2026-11-14) states the pass
state of the remapped live files under /Users/sac/smalt/test/integration,
/Users/sac/smalt/test/internal, /Users/sac/smalt/test/data_plane,
/Users/sac/smalt/test/smalt, /Users/sac/smalt/test/courts is UNVERIFIED.
`/Users/sac/smalt/docs/CENSUS.md` still points at a retired runner.

## Acceptance

- Run the remapped test files named in WIRE_PARITY.md; save output to
  `/Users/sac/smalt/docs/verification/azure-gate-2026-11-14.md` with per-row pass/fail.
- Add the Functions row to WIRE_PARITY.md; update AZ2-matrix.json from results.
- Expected: every cited path exists (an existence loop prints no MISSING); AZ2 Standing
  derived from the run, not file presence.

## Falsifier

Rename one cited test file; the existence loop must print MISSING for it.

## Owned files

/Users/sac/smalt/docs/azure-parity/AZ2.md, /Users/sac/smalt/docs/azure-parity/AZ2-matrix.json,
/Users/sac/smalt/docs/WIRE_PARITY.md,
/Users/sac/smalt/docs/verification/azure-gate-2026-11-14.md, /Users/sac/smalt/docs/CENSUS.md

## Depends-on

none

## Size

M

## References (path : LOC)

- /Users/sac/smalt/docs/azure-parity/AZ2.md : 17 lines
- /Users/sac/smalt/docs/azure-parity/AZ2-matrix.json : 9 lines
- /Users/sac/smalt/docs/WIRE_PARITY.md : 296 lines
- /Users/sac/smalt/docs/CENSUS.md : 75 lines
- /Users/sac/smalt/test/integration/ : 165 files, 42401 lines total
- /Users/sac/smalt/test/internal/ : 114 files, 22781 lines total
- /Users/sac/smalt/test/data_plane/ : 12 files, 1546 lines total
- /Users/sac/smalt/test/smalt/ : 36 files, 4501 lines total
- /Users/sac/smalt/test/courts/ : 19 files, 4382 lines total
- /Users/sac/smalt/docs/verification/azure-gate-2026-11-14.md : NEW (0 lines, to be created; est.
  LOC: 60; per-row pass/fail table for ~30 WIRE_PARITY rows plus header)

## Result

Standing: UNVERIFIED (no test executed; existence loop only: 42 paths, 0 MISSING)

Changed: docs/verification/azure-gate-2026-11-14.md (new ~60 LOC, rows PENDING), docs/azure-parity/AZ2.md,
docs/azure-parity/AZ2-matrix.json, docs/CENSUS.md (pointer to the gate receipt). WIRE_PARITY.md already had
the Functions row (line 175); unchanged.

Acceptance command: the Command block in /Users/sac/smalt/docs/verification/azure-gate-2026-11-14.md,
then replace PENDING rows with PASS/FAIL.
