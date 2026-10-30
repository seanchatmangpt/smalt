# T03 — Courtroom consumer court

- window: v26.10.29 · status: LANDED (PARTIAL_ALIVE — receipt
  `receipts/r3-t03-consumer-court.md`; legs 1-2 ALIVE, leg 3 BLOCKED on the
  RESP3/HELLO pinion flip — see FINAL.md) · depends: T01, T02

## Scope

End-to-end court proving courtroom-platform-az runs on the smalt substrate
with zero cloud:

1. Materialize the consumer repo at its HEAD via `git archive` into /tmp
   scratch (the canonical checkout is never written).
2. `npm ci` + `npm run check` under node 22 (engines `>=22 <25`).
3. Boot the smalt substrate with `:redis_port` + `:saml_idp_port` enabled.
4. Boot `apps/api` with `REDIS_URL=redis://127.0.0.1:6380`,
   SAML config pointing at the smalt IdP; assert `stores.kind === "redis"`.
5. Drive the SP-initiated flow through the real API: `GET /api/sso/start`
   → smalt IdP `/sso` → auto-POST `SAMLResponse` to `/saml/acs` → session
   cookie → `GET /api/auth/me` 200 — validated by the consumer's own
   `@node-saml` validator + Redis-backed SAML replay cache.

## Known toolchain finding (consumer repo, not smalt)

`.nvmrc` pins `20` while `package.json` engines demand `>=22 <25`
(`engine-strict` via `.npmrc`): a node-20 shell fails `npm ci` outright.
The court pins node 22 explicitly. Reported upstream to the operator;
not fixed here (no writes to the consumer repo).

## Falsifier

`stores.kind === "memory"` (Redis leg silently degraded), or the ACS
route rejects the smalt-minted response, or any leg faked with a mock
SP/IdP — the court FAILs. Exit contract: 0 pass / 1 assert fail /
2 substrate never up / 3 harness-skip (loud).
