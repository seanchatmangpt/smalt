# POSH-006: posh admission courts (smalt discipline carries over)

## Task
Court harness for posh changes, following smalt shim-court / provider-court
patterns:
- posh-court: protocol conformance (framing fuzz), ARM probe ladder vs substrate,
  provider ladder (plan/apply/destroy/zero-drift/residue), non-vacuity mutation
  (corrupt a response envelope -> court must flip).
- just recipes: `just posh-court`, wired into `just court` as a leg.
- Receipts to docs/jira/posh/<version>/receipts/.

## Acceptance
`just posh-court` green on clean tree; mutation shim FAILS the court (non-vacuity).

## Falsifier
A posh-court that cannot fail on an injected defect is VACUOUS and blocks merge.

## Status (2026-10-30, lane F8)

Implemented: the full 8-stage ladder lives in `justfile.d/58-posh.just` — the 7
DoD stages above (vet / alloc-test / build+static / fence / smalt-wire /
tf apply / zero-drift) plus a stage-8 mutation non-vacuity leg
(tamper-reject tests: `TestHTTPEnvelopeOverTCPListener`, `TestVerifyTurnstile`;
the flip is the non-vacuity proof). Exit contract 0/1/3, typed `[POSH-*]` lines.

Pending: wiring into the repo-level gates — zero references in
`justfile.d/07-court-x2.just`, `justfile.d/09-verify-all.just`,
`justfile.d/18-shim-court.just`; `just court` / court-x2 / verify-all do not
yet run posh-court as a leg.
Green-run receipt in flight (lane F3) to docs/jira/posh/v26.10.30/receipts/.
