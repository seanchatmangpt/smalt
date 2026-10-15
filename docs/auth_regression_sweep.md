# Auth Regression Sweep Receipt

Date: 2026-10-15 · Checkout: /Users/sac/smalt · Subject: post-IssuerMismatch-fix
(bearer.ex request-authority-derived `iss`, coordinator fix) verification sweep.
All runs real, MIX_ENV default (test), on the canonical checkout. No code edits.

## Per-suite verdicts

| Suite | Command | Result |
|---|---|---|
| auth_enforce + c6_oauth | `mix test test/auth_enforce_test.exs test/compliance/c6_oauth.exs` | 27 tests, 0 failures |
| c1_arm | `mix test test/compliance/c1_arm.exs` | 21 tests, 0 failures |
| c3_cosmos (incl. master-key rows; suite sets auth modes internally) | `mix test test/compliance/c3_cosmos.exs` | 21 tests, 0 failures |
| arm_gateway + lro + apiversion_matrix | `mix test test/smalt_arm_gateway_test.exs test/lro_test.exs test/apiversion_matrix_test.exs` | 148 tests, 0 failures |
| mcp | `mix test test/mcp_test.exs` | 20 tests, 0 fails |

Aggregate: 237 tests, 0 failures across all suites. Zero findings.

## Live end-to-end (enforce mode, private ports 19443/18443/19545/15672/15673)

Booted full Smalt.Application via `mix run --no-start /tmp/smalt_auth_e2e.exs`
(auth_mode=:enforce asserted in-script). Script: /tmp/smalt_auth_e2e.exs.

| Step | Result |
|---|---|
| STS mint (POST /oauth2/v2.0/token, client_credentials) | 200, 643-byte JWT |
| PUT /subscriptions/sub-e2e/resourcegroups/rg-e2e (valid token) | **201** |
| GET same (valid token) | **200** |
| Tampered token (sig payload altered) | **401** InvalidAuthenticationToken/SignatureVerificationFailed |
| Wrong-aud token (self-signed aud=graph.microsoft.com, valid sig) | **401** InvalidAuthenticationTokenAudience/AudienceMismatch |
| No token | 401 MissingBearerToken |

End-to-end verdict: PASS. The IssuerMismatch fix holds live: tokens minted from
the STS at the same request authority verify against the bearer plug (201/200),
while tampered/mis-audience/absent tokens are refused 401.

## Notes

- Fresh `MIX_BUILD_ROOT` could not compile deps (`:sparql` lexer path bug with
  alternate build roots); used the prebuilt default `_build` instead. Pre-existing.
- AMQP/EventHubs listeners collide with concurrent lanes on 5672/5673 unless
  `:amqp_port`/`:event_hubs_port` are overridden — set to 15672/15673 in the e2e script.
- No storageAccount PUT route exists at the account level (child-resource routes
  only); the live PUT/GET used a resource group — a real ARM resource surface.
