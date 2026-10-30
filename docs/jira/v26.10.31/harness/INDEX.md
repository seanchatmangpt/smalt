# INDEX — Next.js Test Harness Window v26.10.30 (canonical relocated to smalt)

Relocated from
`/Users/sac/cai/courtroom-platform-az/docs/jira/nextjs-harness/v26.10.30/` by
smalt consolidation lane 4, 2026-10-30. Consumer dir retains a snapshot plus
`CANONICAL-IN-smalt.md` pointer.

## PRD

`v26.10.30/PRD.md` — Next.js application test harness & verification suite
against the local Smalt substrate (kind, loopback, offline-first; anonymized
multi-tenant legal-technology enterprise context: SOC 2, client-matter
isolation, CRMH audit exports, SIEM matter attribution).

- Chicago-style (classical, state-based): real HTTP wire exchanges,
  cryptographic receipts, fail-closed assertions; zero-mock policy.
- KPIs: full suite < 45 s; 0% mocked exchanges; 0 flakes across 1,000 loops;
  mutation kill rate > 90% on inverted requests/headers.
- Scope: client React components + server runtime (route handlers / server
  actions against loopback-configured cloud SDKs) — provisioning, secret
  retrieval, audit telemetry, blob lifecycle.

## Ticket list

`00-charter.md` + `HRN-001..HRN-015` (one file each, all copied under
`v26.10.30/`):

| Ticket | Subject |
|---|---|
| HRN-001 | Tenant-case provisioning |
| HRN-002 | Container consolidation |
| HRN-003 | Key-vault lifecycle |
| HRN-004 | CRMH compliance |
| HRN-005 | SIEM telemetry |
| HRN-006 | API version ceilings |
| HRN-007 | Terminal UX jidoka |
| HRN-008 | NFR performance |
| HRN-009 | NFR hermetic isolation |
| HRN-010 | NFR cleanup |
| HRN-011 | NFR concurrency |
| HRN-012 | 3-stage gates |
| HRN-013 | Mutation court |
| HRN-014 | Runner config |
| HRN-015 | Definition-of-Done court |

## Suite status — 48 pass / 2 skip

As-of receipts on disk in the consumer repo (all dated 2026-10-30):

- `receipts/hrn004-crmh-harness.md` (consumer repo `receipts/`): full harness
  run `npx vitest run --config vitest.harness.config.ts` (15 files) →
  **Tests 48 passed \| 2 skipped (50), exit 0**. Same receipt: the CRMH file
  alone is 3 pass / 2 loud typed SKIP (CONTAINER-NAMESPACE-DISCONNECTED;
  MANAGEMENT-POLICY-ROUTE-ABSENT — registered smalt divergences, exit 0).
- `receipts/gaps/h6-hrn-006-tc-ver.md`: version suite 5/5 pass, 3 consecutive
  runs; TC-VER-002 carries one registered divergence (registries@2023-07-01
  admitted 201 instead of refused — AcrRouter version-presence-only upstream).
- `v26.10.30/receipts/hrn-009-hermetic.md` (copied): hermetic guard +
  runtime fail-fast 3/3 pass, shim-court non-vacuity witnessed.
- `v26.10.30/receipts/mutation-court-2026-10-30.md` (copied): 20 mutations,
  14 flipped; inversion class 14/14 killed = 100% (target > 90%); VERDICT
  PASS.
- `v26.10.30/receipts/harness-court-2026-10-30.md` (copied): earlier court
  REFUSED (substrate down, exit 3 loud skip) — superseded by the 48/2 run.

## Open FAIL rows (honest, as-of 2026-10-30 ~14:33 disk state)

From `v26.10.30/receipts/dod-landing.md` (DoD totals PASS=5 FAIL=10
PLANNED=5, exit 1, two stable runs). Re-read at use time — the premise
"vault/crmh/version receipts pending" is now PARTIALLY STALE:

- **Resolved since the DoD landing**: HRN-004 crmh and HRN-006 version now
  have receipts on disk (see above) — those FAIL rows were receipt-missing,
  and the receipts landed after the DoD court ran.
- **HRN-003 vault — still open.** No vault receipt anywhere in the consumer
  repo `receipts/` tree. DoD witnessed 2 failing tests
  (`tc-vault-001-retrieval` class) at DoD time. Mutation court M05–M07/M16/M17
  killed on `tc-vault-002-fail-closed` only. Suites exist on disk
  (`apps/web/test/harness/vault/`, 3 files).
- **HRN-001/002/008/010/011 — suites green, per-lane receipts
  (`receipts/hrnXXX-*.md`) not yet written**; the DoD gate fails by design
  until they land. (HRN-009's receipt is the one that landed.)
- **HRN-005 SIEM — flapping** at DoD time (RUN 1 failed on
  `mutated-M08.test.ts` — mutation-probe residue left in the suite tree; RUN 2
  passed). Receipt missing. `mutated-M08.test.ts` residue still needs removal.
- **HRN-007 terminal UX, HRN-012 stage gates, HRN-013 mutation-court script,
  HRN-014 runner config — PLANNED**, subjects not landed at DoD time
  (mutation-court receipt exists for the court *run*; the
  `scripts/mutation_court.sh` gate itself was not landed).

## Receipts index (copied under `v26.10.30/receipts/`)

- `dod-landing.md` — HRN-015 DoD court; verdict FAIL exit 1 with attributed
  FAILs; falsifier: a PASS row whose gate did not execute.
- `mutation-court-2026-10-30.md` — M01–M20 table; PASS.
- `hrn-009-hermetic.md` — hermetic isolation; ALIVE.
- `harness-court-2026-10-30.md` — REFUSED (substrate down, exit 3).
