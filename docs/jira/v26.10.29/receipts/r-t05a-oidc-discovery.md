# Receipt: R-T05a — OIDC IdP, discovery + token legs (lane L17)

Standing: **ALIVE** — real Bandit listener (http + https with the dev cert),
real HTTP/TLS, real spec-conformant client (`openid-client` 6.8.8, node
22.23.4) completed discovery → JWKS → PKCE S256 token exchange with full
library-side id_token verification (signature vs JWKS, iss/aud/exp/nonce) —
and a replay probe was refused. In-repo court: 11/11 (`mix test` exit 0).

## Files landed

- `lib/smalt/identity/oidc_idp.ex` (new) — `Smalt.Identity.OidcIdp`, Bandit
  plug router: per-tenant `/.well-known/openid-configuration` (both the
  tenant-level and the Entra v2 issuer-path forms), per-tenant
  `/.well-known/oauth-authorization-server` (RFC 8414, both forms),
  `/discovery/v2.0/keys` JWKS, `POST /oauth2/v2.0/token`
  authorization-code + PKCE (S256 and plain). `child_spec/1` mirrors
  SamlIdp: `config :smalt, :oidc_port` (default 9446),
  `Smalt.Config.bind_ip()` law, `:oidc_scheme` (`:http` default, `:https`
  serves `:oidc_cert_path`/`:oidc_key_path` with top-level Bandit
  `certfile`/`keyfile`).
- `lib/smalt/identity/oidc_jwks.ex` (new) — dev-cert/dev-key loader
  (`:persistent_term` cache), JWKS document (`kty RSA`, `n`, `e`, `kid` =
  base64url(SHA-256 of DER RSAPublicKey), `use sig`, `alg RS256`), RS256
  JWS signing that mirrors `Smalt.Security.ReceiptSigner.sign/1` byte-shape
  but carries `kid` (ReceiptSigner's fixed header has none).
- `lib/smalt/identity/oidc_code_store.ex` (new) — lazy shadow ETS
  (`:smalt_oidc_codes`, named, public, `read_concurrency`), created under a
  `:global.trans` lock, `heir` to the init process (real-pid form; see
  divergences). Single-use is atomic (`:ets.take`).
- `test/integration/oidc_idp_test.exs` (new) — in-repo court: real Bandit
  server on a private random port, real HTTP over Finch, real `:public_key`
  RSA verification of the minted id_token against the JWKS-served key;
  replay/verifier/redirect/grant-type/unknown-code refusal courts;
  honest-advertising courts (`authorization_endpoint` absent from both
  discovery documents); Entra v2 discovery-path court.
- `lib/smalt/plane/identity_supervisor.ex` — **disclosed minimal attach**
  (outside the strict ownership set, per the lane task's mount law):
  `Smalt.Identity.OidcIdp` added as a third `one_for_one` child alongside
  `StsGate` + `SamlIdp`. The T02 lane (r2-t02) lists this file as
  contract-owned; disclosed here for both receipts.
- `docs/jira/v26.10.29/receipts/r-t05a-oidc-discovery.md` (this receipt).

## Commands / exits (re-read at use time)

- `MIX_BUILD_ROOT=_build-l17 MIX_ENV=test mix compile` → rc 0
  (`Generated smalt app`).
- `MIX_BUILD_ROOT=_build-l17 MIX_ENV=test mix test test/integration/oidc_idp_test.exs`
  → exit 0, tail:
  `Finished in 0.1 seconds (0.00s async, 0.1s sync)` / `Result: 11 passed`.
- Node gate (scratch `/tmp/l17-oidc-court/node-court`, NOT the consumer
  repo; `npm install openid-client` → 6.8.8):
  `nvm use 22 && NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem node court.mjs`
  → `L17 GATE COURT PASS`. Full transcript embedded below.

## Real-client court transcript (verbatim)

```
DISCOVERY_OK issuer=https://127.0.0.1:9446/organizations/v2.0
token_endpoint=https://127.0.0.1:9446/organizations/oauth2/v2.0/token
jwks_uri=https://127.0.0.1:9446/organizations/discovery/v2.0/keys
HONEST_ABSENCE: no authorization_endpoint advertised (L18 lane)
JWKS_FETCH_OK keys=1 kid=JrBUbcDSSqyGHn_Lce_0lA4S7wCcLLmpH9ZjgMvzaKg kty=RSA alg=RS256
TOKEN_EXCHANGE_OK
token_type=bearer
id_token=eyJhbGciOiJSUzI1NiIsImtpZCI6IkpyQlViY0RTU3F5R0huX0xjZV8wbEE0...
id_token_claims={"aud":"l17-gate-client","exp":1793341961,"iat":1793338361,"iss":"https://127.0.0.1:9446/organizations/v2.0","name":"Smalt User","nbf":1793338361,"nonce":"l17-gate-nonce","oid":"l17-gate-subject","sub":"l17-gate-subject","ver":"2.0"}
REPLAY_REFUSED_OK (server responded with an error in the response body)
L17 GATE COURT PASS
```

## Notes and divergences (honest standing)

1. Honest advertising: the discovery documents advertise only what exists.
   `authorization_endpoint` is ABSENT (the /authorize leg is L18); codes are
   seeded through `OidcCodeStore.insert/2`. The node court asserts this
   absence explicitly (`HONEST_ABSENCE` line).
2. erts-17.1 (OTP 29) refuses the `{:heir, :init, nil}` atom shorthand
   (`:ets.new` → "invalid options"; probed: real-pid OK, `:init` atom
   refused in all data forms). Same semantics hold via
   `{:heir, Process.whereis(:init), nil}` — heir to the init process by
   pid. The runtime's ETS-TRANSFER messages to init are observed and
   benign (init ignores them).
3. Bandit wants TLS material as top-level `certfile`/`keyfile`
   (`transport_options` is refused by `Bandit.validate_options/3`).
4. openid-client v6 checks key is `pkceCodeVerifier` (v5's
   `checks.code_verifier` is ignored — first probe produced the typed
   "code_verifier required for this code" refusal, which doubles as a
   server-side PKCE-missing negative court).
5. openid-client (oauth4webapi) refuses http transport (spec law). The IdP
   therefore serves `:oidc_scheme :https` with the dev cert (SAN covers
   127.0.0.1 / localhost), CA trusted via `NODE_EXTRA_CA_CERTS` on the
   client side. http remains the default scheme.
6. Sibling-lane churn during the wave (not mine, disclosed for the census):
   `saml_slo.ex` typespec literal, `mcp/tool/arm.ex` missing brace,
   `messaging/amqp/frame_codec.ex` (dev/test compile), and
   `config/test.exs:73` corrupted literal `9ishing092` — each observed
   once via bounded-poll compile attempts and gone on the next attempt
   (owners landed fixes within the SLA). Census law: compile-abort is not
   a failure count.
7. The narrowed-load-path ExUnit court (`/tmp/l17-oidc-court/run_exunit.exs`,
   deps from `_build-l17` + lane beams in `/tmp/l17-elixirc`) was the
   interim gate while siblings held the shared compile; the final gate is
   the standard `mix test` path (exit 0, 11 passed) after the tree healed.
   Scratch under /tmp only; no consumer-repo writes outside ownership.

## Addendum (lane L18, 2026-10-29 — disclosure carried in both receipts)

L18 landed the /authorize + consent leg and flipped the honest absence this
receipt documents: `authorization_endpoint` (plus the `refresh_token` grant
and `response_modes_supported ["query"]`) is now advertised by both metadata
documents. Disclosed edits to files this receipt landed:

- `lib/smalt/identity/oidc_idp.ex`: two one-line authorize delegations;
  token-endpoint refresh-grant dispatch (old body renamed
  `handle_code_grant/1`, untouched); refresh-token mint on code exchange;
  `token_response/2` refresh fields; both metadata docs advertise
  `authorization_endpoint` + `refresh_token` grant; moduledoc honesty flip.
- `test/integration/oidc_idp_test.exs`: the three `authorization_endpoint`
  absence assertions flipped to presence assertions; the
  `grant_types_supported` line now lists `refresh_token`. All L17 refusal
  courts unchanged and passing (11 of the 29-test gate).
- Authoritative receipt: `r-t05b-oidc-authorize.md`.
