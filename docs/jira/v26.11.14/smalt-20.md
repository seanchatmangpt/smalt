# smalt-20 emulator cost and resource baseline for hosted run

Standing: UNVERIFIED

## Problem

No measured memory/CPU/disk baseline exists for running smalt with the GCP and AWS
surfaces enabled, so hosting cost cannot be estimated. Existing bench lanes
(`bench/`, `/Users/sac/smalt/justfile.d/15-bench.just`,
`/Users/sac/smalt/justfile.d/28-stress.just`) predate these
surfaces. Related arcus pre-existing failures (gcp_emulator/sdlc HCL_UNSUPPORTED, nil
deref at /Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go:153) are out of scope but must be
disclosed, not counted as smalt
results.

## Acceptance

`just --justfile /Users/sac/smalt/Justfile --list | grep -i bench` shows the recipe
used; run it with the GCP+AWS surfaces enabled; record peak RSS and idle RSS in
`/Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-20-baseline.md` with command, exit code, SHA.

## Falsifier

Receipt reports figures with no command/exit code, or a rerun differs by more than 2x
on idle RSS.

## Owned files

- /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-20-baseline.md

## Depends-on

smalt-18 (image to measure).

## Size

M

## References (path : LOC)

- /Users/sac/smalt/bench/ : 25 files, 4119 lines total
- /Users/sac/smalt/justfile.d/15-bench.just : 11 lines
- /Users/sac/smalt/justfile.d/28-stress.just : 10 lines
- /Users/sac/smalt/lib/smalt/gcp/ : 17 files, 3579 lines total
- /Users/sac/smalt/lib/smalt/aws/ : 11 files, 2064 lines total
- /Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go : 302 lines
- /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-20-baseline.md : NEW (0 lines, to be created;
  est. LOC: 40; basis: command, exit, SHA, peak and idle RSS lines)

## Result

Standing: UNVERIFIED (no execution observed; no RSS figures fabricated)
Files: /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-20-baseline.md (~35 LOC, template with unfilled slots)
Acceptance: `just --justfile /Users/sac/smalt/Justfile --list | grep -i bench`, then sample BEAM RSS idle/peak during `just test-stress` with GCP+AWS enabled, twice; fill the receipt table.
