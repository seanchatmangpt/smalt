# r-p03 — Browser + openid-client OIDC code/PKCE flow (P03, CLM-03)

- window: v26.10.30 · date: 2026-10-30 · tier: in-cluster (kind `smalt`)
- standing: **ALIVE**

## Claim witnessed

Real headless chromium (driver pod) + openid-client v6 (the production
client stack) against the substrate's OIDC face:

1. Discovery (issuer `http://localhost:9446/organizations/v2.0`, the
   consumer's documented localhost dev shape, via the in-pod TCP pipe —
   no TLS bypass anywhere).
2. Browser drives `/authorize` (PKCE S256) and the substrate's
   auto-submit consent form (L18's).
3. Code + state land on the local redirect server; openid-client runs
   the token exchange with the verifier.
4. The library verifies the RS256 `id_token` against the live JWKS
   (iss/aud/nonce checked), access + refresh tokens issued.

```json
{"verdict":"P03-PASS","sub":"smalt-user",
 "iss":"http://localhost:9446/organizations/v2.0",
 "aud":"courtroom-p03","alg":"RS256-verified-by-library",
 "hasAccessToken":true,"hasRefreshToken":true}
```

## Environment notes (receipted, honest)

- `calculatePKCECodeChallenge` is ASYNC in openid-client v6 — an
  un-awaited Promise stringified into the challenge and the substrate's
  token leg correctly refused (`invalid_grant: PKCE S256 verification
  failed`). The refusal court fired against the harness bug; the fix was
  harness-side.
- The https issuer variant was attempted first and is lawful
  infrastructure (r30 chain + NODE_EXTRA_CA_CERTS for node), but
  Chromium's own root store still refuses the substrate CA at the
  browser layer — the localhost dev shape is the consumer's own
  documented browser law; https trust remains witnessed for node-tier
  clients (r-p01 notes + the r30 front probes).
