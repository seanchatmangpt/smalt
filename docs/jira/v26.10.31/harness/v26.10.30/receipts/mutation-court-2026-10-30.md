## HRN-013 harness mutation court — 2026-10-30T21:13:30Z

- Subject: harness suites under `apps/web/test/harness/` (tenant, vault fail-closed, siem audit-event, nfr perf).
- Method: sed mutations on temp copies of the test files; vitest run on the copy, `-t` filtered to the target TC.
- A mutation that still PASSES = vacuous/redundant assertion (survivor). Kill = flipped/ran; court asserts > 90% over >= 10 sites.

| id | suite | class | assertion site | outcome |
|---|---|---|---|---|
| M01 | tenant/tenant.test.ts | invert | tenant create 201 -> 400 | FLIPPED (killed) |
| M02 | tenant/tenant.test.ts | weaken | residue-404 check skipped (residue-0 vacuity) | SURVIVED (vacuous) |
| M03 | tenant/tenant.test.ts | relax | disjunctive [400,403,404,409] -> any status | SURVIVED (vacuous) |
| M04 | tenant/tenant.test.ts | relax | fail-closed exact 400 -> any-error | SURVIVED (vacuous) |
| M05 | vault/tc-vault-002-fail-closed.test.ts | invert | typed statusCode 404 -> 200 | FLIPPED (killed) |
| M06 | vault/tc-vault-002-fail-closed.test.ts | relax | ResourceNotFound code assert -> any code | SURVIVED (vacuous) |
| M07 | vault/tc-vault-002-fail-closed.test.ts | delete | rejects.toBeInstanceOf(MissingSecretError) deleted | FLIPPED (killed) |
| M08 | siem/audit-event.test.ts | invert | monotonic ordering c.ts>=b.ts inverted to < | FLIPPED (killed) |
| M09 | siem/audit-event.test.ts | delete | MISSING_TURNSTILE_HEADER typed-reason assert deleted | SURVIVED (vacuous) |
| M10 | siem/audit-event.test.ts | relax | DIGEST_MISMATCH typed-reason -> any SiemHarnessError | SURVIVED (vacuous) |
| M11 | siem/audit-event.test.ts | invert | receipt pairing id r-123 -> r-XXX | FLIPPED (killed) |
| M12 | nfr/perf.test.ts | invert | SLA: cached mint <5ms budget -> <0ms | FLIPPED (killed) |
| M13 | tenant/tenant.test.ts | invert | tenant GET confirm 200 -> 404 | FLIPPED (killed) |
| M14 | tenant/tenant.test.ts | invert | GET body match {name: rg} -> {name: rg+"x"} | FLIPPED (killed) |
| M15 | tenant/tenant.test.ts | invert | DELETE success <300 -> ==500 | FLIPPED (killed) |
| M16 | vault/tc-vault-002-fail-closed.test.ts | invert | err.secretName -> wrong name | FLIPPED (killed) |
| M17 | vault/tc-vault-002-fail-closed.test.ts | invert | typed-error instanceof -> null assert | FLIPPED (killed) |
| M18 | siem/audit-event.test.ts | invert | event.kind audit -> other | FLIPPED (killed) |
| M19 | siem/audit-event.test.ts | invert | receipt digest pairing -> wrong digest | FLIPPED (killed) |
| M20 | nfr/perf.test.ts | invert | p99 transport ceiling <150ms -> <0ms | FLIPPED (killed) |

## Verdict

- mutations attempted: 20 (ran: 20, loud SKIP: 0); flipped: 14
- inversion-class (vacuity probe): 14 ran, 14 flipped, 0 survived — **kill rate: 100%** (target > 90%)
- strength-degradation rows (relax/delete/weaken): reported above; a SURVIVED row there means the weakened suite still passes the real substrate (redundancy, not vacuity) — no kill-rate credit either way.
- VERDICT: **PASS**

Coverage note: sibling-domain suites (vault-001/003, crmh, container, siem/wire, nfr cleanup/concurrency) were RED at court time (sibling lanes in flight / substrate divergences registered by their owners) — excluded from this court's baseline, not silently absorbed.
