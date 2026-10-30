# P02 — SAML Single Logout round-trip witnessed end to end

- window: v26.10.30 · id: CLM-02 (Scenario 3) · receipt: r-p02-slo-roundtrip.md
- depends: L16 (SLO + c14n) landed.

## Claim

Browser-driven logout traverses consumer `POST /api/auth/logout` -> signed
`<LogoutRequest>` at the IdP -> signed `<LogoutResponse>` -> landing at the
login surface; subsequent `/dashboard` access redirects; the session record
is provably gone at the substrate (direct store audit, not UI inference).

## Falsifier

Session surviving the round trip, or logout validated only by UI redirect
without a store-level eviction witness.
