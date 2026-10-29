# BK-CENS6 — census reconcile wave 6: bkmon3r registered, BK-POWLH3-1 closed

**Standing:** ALIVE
Context: solo

Lane: BK-CENS6, `MIX_BUILD_ROOT=_build-bkcens6` (lease). Files owned/edited:
`test/internal/internal_tier_census_test.exs` (registration + exemptions +
observables), this receipt.

## Drift confirmed (real output, this session)

Pre-fix census run:
`MIX_BUILD_ROOT=_build-bkcens6 scripts/fast_test.sh test/internal/internal_tier_census_test.exs`
→ `Result: 1/6 passed, Failed: 5 tests` — all five failures named
`bkmon3r_deadjoin_court_test.exs`:

- population fence (unregistered file),
- off-allowlist module references (`Smalt.Metrics`,
  `Smalt.Test.Internal.Bkmon3rDeadjoinCourtTest`),
- forbidden client tokens (raw Erlang HTTP client call + Jason decode line),
- status-literal asserts (5 lines),
- ARM path literals (2 lines, Azure Monitor metrics REST path).

Exactly the 5 census legs BK-POWLH3's batched run witnessed (BK-POWLH3-1).

## Registration

- `"bkmon3r_deadjoin_court_test.exs" => :wire` — real HTTP/1.1 over loopback
  against the self-booted ARM gateway router (per bkmon3r-deadjoin-fix.md);
  on-the-wire status checks, so the status-literal rule does not apply
  (:wire class).
- Exemptions: `[:client_token, :arm_literal]` — client-token fires on the
  raw Erlang HTTP client harness + Jason decode; arm_literal fires on the
  Azure Monitor metrics REST path the court builds (interpolated
  subscriptions/resourceGroups/providers segments).
- Observables allowlist extended with `Smalt.Metrics` (the monitor metrics
  module the fallback join lives in) and the test-module self-reference
  `Smalt.Test.Internal.Bkmon3rDeadjoinCourtTest`.

## Verification (real output, this session)

1. Census post-fix → `Result: 6 passed` (`_build-bkcens6`).
2. The registered file run once green:
   `MIX_BUILD_ROOT=_build-bkcens6 scripts/fast_test.sh test/internal/bkmon3r_deadjoin_court_test.exs`
   → `Result: 4 passed` (wall 6s).
3. Final sweep: every `test/internal/*.exs` filename grepped against the
   registered map → 92 files, zero unregistered (BK-CENS5 closed store4,
   this wave closes bkmon3r; no other drift exists).

BK-POWLH3-1 is CLOSED: batched census legs no longer fail on
bkmon3r_deadjoin_court_test.exs.
