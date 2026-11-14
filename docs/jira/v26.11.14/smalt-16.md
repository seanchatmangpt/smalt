# smalt-16-register-census-hygiene

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` has OPEN rows spanning KD-10, KD-14,
KD-18 (whose
Status column says CLOSED-* while the row is still counted OPEN by grep), KD-75..KD-179, and
KD-GCP/AWS rows. The header says "Every row is OPEN", which contradicts closed rows. Also
`/Users/sac/smalt/docs/CENSUS.md` is a RETIRED@64f6099 witness record (successor
`/Users/sac/smalt/verification/ts/census.test.cjs`), and `/Users/sac/smalt/docs/WIRE_PARITY.md`
notes live pass state of
remapped paths is UNVERIFIED. Related pending items: fnox.io hosting is authored, not
deployed, and registration awaits ACTIVE (tracked in /Users/sac/fnox, not smalt).

## Acceptance

- Command: `grep -c "| OPEN" /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`; expected:
  count equals
  rows whose Status column starts with OPEN, and the header sentence is corrected.
- `/Users/sac/smalt/docs/CENSUS.md` links the live successor and records one live run result.
- `/Users/sac/smalt/docs/WIRE_PARITY.md` path-remap note replaced by an observed pass state.

## Falsifier

A row's Status column disagrees with the OPEN count, or the header still says every row is OPEN.

## Owned files

- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
- /Users/sac/smalt/docs/CENSUS.md
- /Users/sac/smalt/docs/WIRE_PARITY.md (remap note only)

## Depends-on

smalt-14, smalt-15 (WIRE_PARITY.md edits serialized).

## Size

M

## References (path : LOC)

- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md : 386 lines
- /Users/sac/smalt/docs/CENSUS.md : 75 lines
- /Users/sac/smalt/verification/ts/census.test.cjs : 499 lines
- /Users/sac/smalt/docs/WIRE_PARITY.md : 296 lines

## Result

Standing: PARTIAL

- KNOWN_DIVERGENCES.md: header corrected (grep count 15 verified = rows whose Status starts OPEN).
- CENSUS.md: successor linked; live run NOT observed (UNVERIFIED, command recorded).
- WIRE_PARITY.md: remap note now states UNVERIFIED with coordinator command; observed pass state BLOCKED on a run.
- Files: /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md, /Users/sac/smalt/docs/CENSUS.md, /Users/sac/smalt/docs/WIRE_PARITY.md (~12 LOC).
- Acceptance: `grep -c "| OPEN" /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (expect 15); run census and paste result.
