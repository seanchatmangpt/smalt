# smalt-08 fnox.io hosting deploy surface and register entry

Standing: UNVERIFIED

## Problem

Observed this session: fnox.io hosting is authored but not deployed, and fnox.io
registration is pending ACTIVE. smalt has no register row for this hosting surface:
`/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` and
`/Users/sac/smalt/docs/WIRE_PARITY.md` contain no fnox.io
entry (`grep -rl "fnox.io" docs` returned nothing in smalt). Also arcus gcp_emulator/sdlc
has pre-existing failures (HCL_UNSUPPORTED, nil deref at
/Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go:153) that block
any hosted GCP simulation claim.

## Acceptance

A KD row (next free id) in `/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` names
fnox.io hosting as OPEN with close condition "registration ACTIVE and
`curl -sI https://fnox.io` returns 200", and cites the arcus failures as evidence.

## Falsifier

Row closed while `curl -sI https://fnox.io` does not return 200.

## Owned files

/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md

## Depends-on

none (external: fnox.io registration ACTIVE)

## Size

S

## References (path : LOC)

- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md : 386 lines
- /Users/sac/smalt/docs/WIRE_PARITY.md : 296 lines
- /Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go : 302 lines (failure cited at line 153)
- /Users/sac/fnox/docs/setup/fnox-io-domain.md : 128 lines

## Result

Standing: UNVERIFIED (docs edit only; no execution observed)

Files changed: /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (+1 row, KD-GCP-06, OPEN)

Acceptance: `grep -n "KD-GCP-06" /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | grep -c "fnox.io"` returns 1; row stays OPEN until `curl -sI https://fnox.io` returns 200.

## Repair

W9-11: KD-GCP-06 moved after KD-GCP-05, dead fnox path fixed, unobserved nil-deref claim downgraded to UNVERIFIED. Rerun: grep -n KD-GCP /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
