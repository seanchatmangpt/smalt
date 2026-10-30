# Charter: Next.js Harness v26.10.30

## Objectives

Build a Chicago-school integration test harness for courtroom-platform-az: real HTTP against
the real API surface at `127.0.0.1:9443`, zero mocks, zero flake, mutation-proven assertions.
The harness proves the platform's tenant lifecycle, container consolidation, Key Vault
lifecycle, CRMH compliance, SIEM telemetry, API versioning, and terminal UX behave as
specified — by executing them, never by simulating them.

## KPIs (all are gates — see HRN-015)

| KPI | Target | Gate |
|---|---|---|
| Suite wall time | < 45 s | timed full-suite job |
| Mock count | 0 | grep gate over test dirs |
| Flake | 0 failures / 1000 loops | CI 1000-loop job spec |
| Mutation kill | > 90% | HRN-013 mutation court |
| SKIP loudness | exit 3, never silent | per-ticket substrate-down rules |

## Domains (7)

1. HRN-001 tenant-case provisioning
2. HRN-002 container consolidation
3. HRN-003 Key Vault lifecycle
4. HRN-004 CRMH compliance
5. HRN-005 SIEM telemetry
6. HRN-006 API version ceilings
7. HRN-007 terminal UX jidoka

Cross-cutting: HRN-008..011 (NFRs), HRN-012 (stage gates), HRN-013 (mutation court),
HRN-014 (runner config), HRN-015 (DoD).

## 3-Stage Gates (HRN-012)

- **PRE**: substrate doctor, port availability, compat-pin.ttl pin freshness.
- **LIVE**: the 7 domains run for real.
- **POST**: zero-drift check, receipt ledger, purge (no state residue).

## NFRs (5)

1. Performance — 15 ms loopback ceiling per request (HRN-008)
2. Hermeticity — offline isolation, no external network (HRN-009)
3. Cleanup — deterministic state, zero residue (HRN-010)
4. Concurrency — parallel workers, no port races (HRN-011)
5. Loud skipping — substrate down ⇒ exit 3 with typed reason, never a silent pass

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Substrate (127.0.0.1:9443) down in CI | suite silently passes nothing | PRE doctor gate fails loudly (exit 3) |
| Port 9443 collisions between workers | flaky connection refused | HRN-011 port lease protocol |
| Token endpoint drift | 401 across whole suite | STS recipe pinned in HRN-014; PRE smoke-mints a token |
| compat-pin.ttl drift | tests pin wrong api-version | PRE re-reads pin file, asserts freshness SHA |
| Vault purge latency | HRN-003 residue across loops | POST purge + disjunctive echo law (deleted-or-echo) |
| 1000-loop cost | slow CI | loop job is a separate nightly lane, not the PR gate |
| Mutation-court cost | slow feedback | run on PR only against touched modules |
