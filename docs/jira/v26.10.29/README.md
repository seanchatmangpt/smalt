# v26.10.29 — Courtroom consumer readiness

Window goal: make [courtroom-platform-az](~/cai/courtroom-platform-az) run
"seamlessly" against the smalt substrate — no cloud, no real Entra, no real
Redis — plus a full capability-validation baseline for the substrate itself.

## Consumer profile (the demand)

courtroom-platform-az = npm-workspaces TS monorepo (Node >=22 <25,
engine-strict): `apps/api` Express SAML SSO (`@node-saml/node-saml`,
`connect-redis`, `redis`), `apps/web` Next.js. Azure touchpoints:
Entra ID SAML (IdP), Azure Cache for Redis (`REDIS_URL`, RESP over TCP),
Container Apps hosting. Zero `@azure/*` deps.

## Gaps closed this window

| Ticket | Gap closed | Standing before | After |
|---|---|---|---|
| T01 | RESP2 wire listener over `AzureCache.handle/2` (`:redis_port`, 6380) | wire dropped by v26.10.28 (r15) | ALIVE |
| T02 | SAML 2.0 IdP face (identity plane, `:saml_idp_port`, 9445) | no SAML/Entra emulation in smalt | ALIVE |
| T03 | Consumer court: real `redis` npm client + `@node-saml` validation of a smalt-minted flow | none | PARTIAL |

Standing after, per receipt (re-read at write time, 2026-10-29):

- T01 ALIVE — `receipts/r1-t01-redis-wire.md`: wire court 13/13 exit 0;
  with azure_cache 28/28 exit 0 (HELLO pinion-flip addendum).
- T02 ALIVE — `receipts/r2-t02-saml-idp.md`: 6/6 courts, exit 0.
- T03 PARTIAL_ALIVE — `receipts/r3-t03-consumer-court.md`: legs 1-2 rc 0;
  leg 3 exit 1 on the RESP3/HELLO pinion (see FINAL.md).

## Constraints honored

- The consumer repo is NEVER written (operator instruction). Consumer lane
  materializes via `git archive` into /tmp scratch.
- v26.10.28 courts (azure_cache integration tier) stay byte-stable: the wire
  listener is additive; AzureCache honesty rows stay truthful for the
  no-wire default and flip only when `:redis_port` is configured.
- Baseline (pre-implementation) court receipts land in `receipts/` first;
  implementation lands after the baseline `mix test` tiers drain
  (compile-freeze law).
