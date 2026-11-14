# smalt-12 Emulator arcus failures and fnox.io hosting receipts

Standing: UNVERIFIED

## Problem

Observed this session: arcus aws/azure/gcp emulator go tests pass, but arcus
gcp_emulator/sdlc carries pre-existing failures (HCL_UNSUPPORTED and a nil dereference
at /Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go:153). Those are unregistered: no KD row
in
/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md names them. fnox e2e test fixes landed
without
a smalt-side witness. The fnox.io hosting is authored, not deployed, and fnox.io
registration is pending ACTIVE, so any hosting claim is UNVERIFIED.

## Acceptance

KNOWN_DIVERGENCES.md gains KD-ARCUS rows for HCL_UNSUPPORTED and the
/Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go:153
nil deref (surface, divergence, evidence receipt, close condition), and
`python3 /Users/sac/smalt/scripts/sdk_coverage.py` exits 0 with them registered. A receipt
/Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-12-hosting.md records `Standing: UNVERIFIED` for
fnox.io deploy until registration reads ACTIVE, with the observing command and output.

## Falsifier

A fnox.io hosting claim in docs without a receipt showing ACTIVE registration and a
deployed endpoint answering, or an sdlc failure not covered by a KD row.

## Owned files

/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (new KD-ARCUS rows appended),
/Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-12-hosting.md.

## Depends-on

None.

## Size

S

## References (path : LOC)

- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md : 386 lines
- /Users/sac/smalt/scripts/sdk_coverage.py : 875 lines
- /Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go : 302 lines
- /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-12-hosting.md : NEW (0 lines, to be created;
  est. LOC: 30; basis: command, output, standing lines of a typical receipt)

## Result

Standing: UNVERIFIED

Files: /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (+2 rows KD-ARCUS-01/02), /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-12-hosting.md (new, 17 LOC).

Acceptance: `python3 /Users/sac/smalt/scripts/sdk_coverage.py` (exit 1 beforehand from unrelated cap-cells per smalt-10 receipt).

## Repair (W9-16)

Standing: UNVERIFIED (edited, not executed)
- Audit HIGH/MED fixed: parity court resolves KD ids against arcus/smalt registers
  (check_parity_receipts.py); arcus gap court requires UNIMPLEMENTED or NOT_FOUND "no such route"
  (observability_gap_test.go) and KD-GA6-1/2 rows refreshed; smalt KD-ARCUS-02 row reworded to
  observed facts. Coordinator reruns: the parity-receipts script, the arcus gcp_emulator Gap test, smalt sdk_coverage.
