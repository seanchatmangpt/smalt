# DoD Landing Receipt — HRN-015 (lane 15)

- **Subject**: `scripts/harness_dod_check.py` + `just harness-dod` (repo
  /Users/sac/cai/courtroom-platform-az)
- **Lane**: HRN-015, harness wave v26.10.30
- **Status**: ALIVE (script runs end-to-end with honest verdicts; final run below)
- **Exit contract**: 0 = all PASS · 1 = any FAIL · 3 = loud skip (nothing live)

## What landed

- `scripts/harness_dod_check.py` — per-HRN verdict court: 15 HRN rows + 5 KPI rows.
  Each row = gate command, expected exit, receipt path; verdicts PASS / SKIP / FAIL /
  PLANNED with typed reasons. PRE gate = real TCP probe of `127.0.0.1:9443`.
  `DOD_FORCE_SUBSTRATE_DOWN=1` runs the exit-contract court (exit 3).
- `just harness-dod` recipe (delegates to the script; coordinated with sibling recipes
  `convention-gates`, `harness-kpi` already in the consumer justfile).

## Derivation source

Lane 0's ticket set landed for HRN-001..005 (plus charter) — rows derived from the
tickets; HRN-006..015 ticket bodies not landed, so those rows were derived from the
charter's 7 domains + 4 NFRs + gates + KPIs table and marked with typed PLANNED reasons
where the subject is absent.

## Cross-lane coordination receipts

- Suite paths re-pointed to the real landed suites under `apps/web/test/harness/`
  (sibling lanes' layout), not the ticket-imagined `apps/api/src/*.harness.test.ts`.
- `scripts/harness_kpi.sh` (lane 14) uses numeric subcommands; rows call `1`/`2`/`3`/`4`.
  First-draft rows called it with names — the gate silently no-op'd with exit 0; fixed.
  Receipt column `-` = the fail-closed gate output itself is the receipt.
- KPI-mutation row: gate exits 0 even with `mutation_court.sh` absent (SKIP inside the
  gate) — classified PLANNED here so the vacuous pass cannot read as coverage.

## Honest verdicts at landing

Landed suites report real verdicts; missing subjects are PLANNED with reasons;
flake-1000-loop stays PLANNED (nightly lane, per lane order). Final gates exercised the
real landed suites under `apps/web/test/harness/` (16 lanes running concurrently):
failing suites are sibling-lane in-flight defects, recorded verbatim below, not masked.

## Verbatim runs (stability, 2x)

### RUN 1 — 2026-10-30T21:12:05Z — verdict FAIL (exit 1)

```
[DOD] harness v26.10.30 — substrate 127.0.0.1:9443: UP (PRE doctor gate)
[DOD-HRN-001] tenant-case provisioning: FAIL — exit ok but receipt missing: receipts/hrn001-tenant.md
    gate: npx vitest run apps/web/test/harness/tenant (expected exit 0)
[DOD-HRN-002] container consolidation: FAIL — exit ok but receipt missing: receipts/hrn002-container.md
[DOD-HRN-003] key-vault lifecycle: FAIL — exit 1 != expected 0: Failed Tests 2 (tc-vault-001-retrieval PUT vault 202-LRO ...)
[DOD-HRN-004] CRMH compliance: FAIL — exit 1 != expected 0: Failed Tests 2 (crmh.test.ts TC-CRMH-001/002 storage face ...)
[DOD-HRN-005] SIEM telemetry: FAIL — exit 1 != expected 0: Failed Tests 1 (mutated-M08.test.ts monotonic timestamps ...)
[DOD-HRN-006] API version ceilings: FAIL — exit 1 != expected 0: Failed Tests 4 (version.test.ts TC-VER-001 admitted roundtrip ...)
[DOD-HRN-007] terminal UX jidoka: PLANNED — terminal UX suites absent; UI rendering claims stay planned until Playwright exists
[DOD-HRN-008..011] NFR perf/hermetic/cleanup/concurrency: FAIL — suites pass, per-lane receipts not yet landed (receipt missing)
[DOD-HRN-012] 3-stage gates: PLANNED — script not landed
[DOD-HRN-013] mutation court: PLANNED — script not landed
[DOD-HRN-014] runner config: PLANNED — ticket not landed; suite absent
[DOD-HRN-015] DoD itself: PASS — exit 0 == expected 0
[DOD-KPI-suite-time] PASS · [DOD-KPI-mock-count] PASS · [DOD-KPI-flake] PASS (witness N=3)
[DOD-KPI-mutation] PLANNED — scripts/mutation_court.sh not landed (lane 13)
[DOD-KPI-skip-loudness] PASS — forced-down court exit 3 == expected 3
[DOD] totals: PASS=5 FAIL=10 SKIP=0 PLANNED=5
[DOD] verdict: FAIL (exit 1)
```

### RUN 2 — 2026-10-30T21:12:20Z — verdict FAIL (exit 1)

Identical totals: PASS=5 FAIL=10 SKIP=0 PLANNED=5, verdict FAIL (exit 1). Divergence
from RUN 1: HRN-005 SIEM — RUN 1 failed on `mutated-M08.test.ts` (1 test), RUN 2 the
suite passed but its receipt is still missing. That flap is real signal from the
sibling SIEM lane (a mutation-probe test file is order/name dependent), not DoD-script
noise. Full transcripts: `/tmp/dod_run1.txt`, `/tmp/dod_run2.txt`.

## Attributed FAILs (sibling-lane findings, not DoD-script defects)

- HRN-003 vault: 2 failing tests (tc-vault-001-retrieval class).
- HRN-004 crmh: 2 failing tests (TC-CRMH-001/002 storage face).
- HRN-005 siem: flapping (1 test failed RUN 1, passed RUN 2) + `mutated-M08.test.ts`
  present in the suite tree — mutation-probe residue.
- HRN-006 version: 4 failing tests (TC-VER-001 admitted roundtrip).
- HRN-001/002/008/009/010/011: suites green, per-lane receipt files not yet written —
  FAIL is by design until those lanes land `receipts/hrnXXX-*.md`.

## Falsifier

A row that reads PASS while its gate did not actually execute (the first-draft
`harness_kpi.sh mock-count` no-op is the witnessed near-miss), or a PLANNED row whose
subject demonstrably exists on disk.
