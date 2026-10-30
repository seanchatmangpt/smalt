# Receipt: R-T05b — OIDC IdP, authorize + consent leg (lane L18)

Standing: **ALIVE** — real Bandit listener (https, dev cert), real node 22
`openid-client` 6.8.8 client ran the full authorization-code + PKCE flow
against the landed surface: discovery (L17's honest absence flipped —
`authorization_endpoint` now advertised) → authorize consent form parse +
browser-equivalent submit → 302 code+state to the callback → PKCE token
exchange with library-verified id_token (signature vs JWKS, iss/aud/exp/
nonce) → refresh-token rotation round trip → replay of the rotated-away
token REFUSED → family revoked (the rotated-to token refused too, typed
400 invalid_grant). In-repo court: 29/29 passed, exit 0, three random seeds
(284691 / 386129 / 933866).

## Files landed

- `lib/smalt/identity/oidc_authorize.ex` (new) — `Smalt.Identity.OidcAuthorize`:
  GET/POST `/{tenant}/authorize` (validate → T02-style auto-submit consent
  form → re-validate → mint code via `OidcCodeStore.insert/2` binding
  challenge + method + client_id + redirect_uri + nonce + sub → 302 with
  code+state), the redirect-URI law (loopback or `:oidc_idp` /
  `:allowed_redirect_uris` allowlist, typed 400 otherwise — `validate_acs/1`
  precedent, public `validate_authorize/1` / `validate_redirect_uri/1` for
  court use), and the refresh-token law: rotating refresh tokens in a lazy
  shadow ETS (`:smalt_oidc_refresh_tokens`, `:global.trans` creation,
  heir-to-init-by-real-pid per the L17 erts-17.1 divergence), atomic
  false→true consume via `:ets.select_replace`, reuse of a consumed token →
  `:ets.select_delete` of the whole family + typed
  `invalid_grant "refresh token refresh token reuse..."`.
- `test/integration/oidc_authorize_test.exs` (new) — 18-test real-server
  court: real Bandit on a private port, real HTTP over Finch, real form
  parse + browser-equivalent submit, real 302 capture, real `:public_key`
  RSA verification against the JWKS-served key; typed-refusal courts
  (response_type / client_id / redirect_uri missing + evil / PKCE missing +
  bad method / scope-without-openid), allowlist court, refresh rotation +
  reuse-revokes-family courts, discovery-flip courts.
- `lib/smalt/identity/oidc_idp.ex` — **disclosed minimal edits** (file is
  dormant-owned by L17; disclosed in r-t05a addendum + here):
  1. two one-line route delegations (`get`/`post "/:tenant/authorize"`)
  2. `handle_token/1` becomes a grant dispatcher (`refresh_token` →
     `OidcAuthorize.refresh_grant/1`); the old body renamed
     `handle_code_grant/1` (one line changed, body untouched)
  3. code-grant success path mints a refresh token;
     `token_response/1` → `token_response/2` adds `refresh_token` +
     `refresh_token_expires_in`
  4. both metadata documents advertise `authorization_endpoint` +
     `refresh_token` grant + `response_modes_supported ["query"]` — the
     disclosed flip of L17's honest absence
  5. moduledoc honesty flip (the "/authorize is a later lane" note).
- `test/integration/oidc_idp_test.exs` — **disclosed minimal flips** (forced
  by the discovery flip; the gate demands both files green): three
  `authorization_endpoint`-absence assertions → presence assertions, one
  `grant_types_supported` line updated. All L17 refusal courts unchanged and
  passing.
- `docs/jira/v26.10.29/receipts/r-t05a-oidc-discovery.md` — addendum
  appended (disclosure carried in BOTH receipts, per the mount law).
- `docs/jira/v26.10.29/receipts/r-t05b-oidc-authorize.md` (this receipt).

## Commands / exits (re-read at use time)

- `MIX_BUILD_ROOT=_build-l18 MIX_ENV=test mix compile` → rc 0
  (`Generated smalt app`).
- `MIX_BUILD_ROOT=_build-l18 MIX_ENV=test mix test
  test/integration/oidc_idp_test.exs test/integration/oidc_authorize_test.exs`
  → exit 0, `Result: 29 passed` (run three times: seeds 284691, 386129,
  933866).
- Node gate (scratch `/tmp/l18-oidc-court/node-court`, NOT the consumer
  repo; openid-client 6.8.8 copied from L17's proved scratch):
  `nvm use 22 && NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem
  node court.mjs` → `L18 GATE COURT PASS`, rc 0. Transcript below.

## Real-client court transcript (verbatim)

```
DISCOVERY_OK issuer=https://127.0.0.1:9446/organizations/v2.0
FLIP_OK authorization_endpoint=https://127.0.0.1:9446/organizations/authorize
JWKS_FETCH_OK keys=1 kid=JrBUbcDSSqyGHn_Lce_0lA4S7wCcLLmpH9ZjgMvzaKg kty=RSA alg=RS256
AUTHORIZE_REQUEST_OK path=/organizations/authorize method=S256
CONSENT_FORM_PARSED action=/organizations/authorize fields=client_id,code_challenge,code_challenge_method,nonce,redirect_uri,response_type,scope,state
CONSENT_REDIRECT_OK status=302 host=localhost:3000 has_code=true state_ok=true
TOKEN_EXCHANGE_OK token_type=bearer
id_token=eyJhbGciOiJSUzI1NiIsImtpZCI6IkpyQlViY0RTU3F5R0huX0xj...
id_token_claims={"aud":"l18-gate-client","exp":1793345412,"iat":1793341812,"iss":"https://127.0.0.1:9446/organizations/v2.0","name":"Smalt User","nbf":1793341812,"nonce":"l18-gate-nonce","oid":"smalt-user","sub":"smalt-user","ver":"2.0"}
REFRESH_TOKEN_MINTED len=46
ROTATION_OK new_refresh_token_differs=true claims.iss=https://127.0.0.1:9446/organizations/v2.0 claims.sub=smalt-user
REPLAY_REFUSED_OK (server responded with an error in the response body)
FAMILY_REVOKED_OK status=400 error=invalid_grant
L18 GATE COURT PASS
```

## Notes and divergences (honest standing)

1. Mount choice: one-line delegations inside `OidcIdp`'s router instead of
   a second Bandit child in `IdentitySupervisor` — an issuer is one origin
   (discovery/token/authorize must share the port); a second listener could
   not be Entra-shaped. The task offered either mount; rationale here,
   disclosure in both receipts.
2. First court run FAILED with "PKCE S256 verification failed" — client-side
   court bug: openid-client v6's `calculatePKCECodeChallenge` is async and
   the un-awaited Promise stringified into the authorize URL as the literal
   challenge "[object Promise]". The server correctly bound it and refused
   the exchange with typed `invalid_grant` — the refusal court fired against
   my own harness bug, then the fixed script passed. Server code unchanged
   by this.
3. Sibling-lane churn during the wave (not mine, disclosed for the census):
   `arm_gateway/router.ex` stray `end`, `arm_gateway/plug/resource_providers
   .ex` missing `end`, `data_plane/blob_storage.ex` `opts \ []` backslash
   typo — each observed via bounded-poll compile probes; owners fixed within
   the ~10-min SLA (blob_storage took ~8 min). Census law: compile-abort is
   not a failure count.
4. **Repair disclosure**: early in the lane I ran `mix deps.clean --all`
   which removed the SHARED `deps/` sources (cors_plug, ash_ex4pm reported
   unavailable tree-wide). Repaired immediately with `mix deps.get` (rc 0,
   lockfile-pinned restore, "Getting sleeplocks/unsafe/thousand_island..."
   completed). Disclosed for the coordinator's census; no other lane's file
   was edited.
5. Env-restore law (typed defect found and fixed in my own test): a key
   restored to a nil VALUE is not an absent key — `Application.put_env/3` of
   nil poisons downstream `Keyword.get(nil, ...)` with FunctionClauseError.
   Fixed in the test's restore path (delete when previous was unset) and
   hardened `allowed_redirect_uris/0` + `consent_subject/0` nil-tolerant.
6. The new `:smalt_oidc_refresh_tokens` ETS emits the same benign
   init ETS-TRANSFER log lines L17 documented for `:smalt_oidc_codes`
   (heir-to-init; init ignores them).
7. Toolchain: asdf-pinned `elixir 1.20.4-otp-29` / `erlang 29.1.2` (the
   PATH-default Elixir 1.19.5 is refused by mix.exs `~> 1.20`).
