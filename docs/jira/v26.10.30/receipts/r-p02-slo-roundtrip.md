# r-p02 — SAML Single Logout round trip (P02, CLM-02)

- window: v26.10.30 · date: 2026-10-30 · tier: in-cluster (kind `smalt`)
- standing: **ALIVE**

## Claim witnessed

Real headless chromium in the `r30-driver` pod: sign-in (P01 flow) →
Sign out click → consumer `POST /api/auth/logout` (session destroyed
server-side) → the IdP SLO face (`/slo`, L16) traversed → landing back
at the sign-in surface (`?error=session_required` — the consumer's
typed error for the post-logout navigation) → a fresh `GET /dashboard`
redirects away → **store audit through the substrate's own RESP wire**:
`{"cleared":true,"remainingKeys":0,"tappedGone":true}` — the redis
session key is provably gone, not UI-inferred.

```json
{"verdict":"P02-PASS","postLogoutUrl":"http://localhost:3000/?error=session_required",
 "backAtSignIn":true,
 "storeAudit":{"cleared":true,"remainingKeys":0,"tappedGone":true}}
```

## Divergences and defects found en route

1. **Unsigned SP SLO accepted** (typed divergence): node-saml signs a
   LogoutRequest only with an SP private cert; the consumer has none —
   the substrate IdP accepted the unsigned request. Receipted as the
   honest SLO posture; the IdP-initiated face (signed) remains the
   stricter path.
2. **Coordinator audit-frame defect**: my first RESP `KEYS` probe
   carried a wrong bulk length (`$18` for a 16-byte pattern) — the
   wire's framer correctly waited for the phantom bytes (fail-closed);
   the court fixed the probe, not the protocol.
3. The redis wire's periodic `controlling_process handoff failed:
   :badarg` warnings (identity pod logs) remain an open wire defect
   for the wire lane — non-blocking here (all court connections
   functioned).
