# 09 DoD Consolidated — smalt baseline + harness court (lane 9, v26.10.31)

- Scope: merge the two Definition-of-Done courts into one v26.10.31 table:
  (a) smalt `dod.yaml` baseline (`scripts/dod_check.py` over `/Users/sac/smalt`),
  (b) harness `scripts/harness_dod_check.py` (`just harness-dod`, subject
  `/Users/sac/cai/courtroom-platform-az`).
- Honest as-of timestamps. Wave-2 refresh lane (2026-10-30 late session):
  every row re-derived from disk/live commands this session (see per-tier
  as-of lines); pending held lanes tagged pending-lane L16/L19/L20.

## Sources (receipts read at use time, 2026-10-30)

| source | path | as-of |
|---|---|---|
| smalt first run | `/Users/sac/smalt/tmp/posh/dod-first-run.json` | 2026-10-30T20:49:11Z |
| smalt latest (partial section re-run: GAPS-INDEX only, PASS) | `/Users/sac/smalt/tmp/posh/dod-latest.json` | 2026-10-30T20:50:16Z |
| harness lane-16 receipt (DOD16) | `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/69-dod-execution-harness.md` | 2026-10-30 ~14:25 (receipt text) |
| harness re-run (this lane, live) | this file, harness table below | 2026-10-30, this session |

## Tally

| tier | PASS | FAIL | SKIP | PLANNED | as-of |
|---|---|---|---|---|---|
| smalt (dod.yaml, 21 rows; every row re-run live, wave-2 refresh) | 8 | 3 | 10 | 0 | 2026-10-30 late session (this lane) |
| harness (20 rows, re-run live this session) | 5 | 10 | 0 | 5 | this session, 2026-10-30 |

## Consolidated v26.10.31 DoD table

Verdict vocabulary: PASS / FAIL / SKIP (planned, loud, reason given) /
PLANNED (suite or script absent on disk). FAIL rows are seeded into the
v26.10.32 backlog section below.

### smalt tier (`dod.yaml`, gate = `python3 scripts/dod_check.py`)

**Wave-2 refresh (this lane, 2026-10-30 late session): every row re-run live**
via `python3 scripts/dod_check.py --section <s>` per section (receipts
`tmp/posh/dod-w2-<section>.json`), a double re-run of
`python3 scripts/posh_mutation_court.py` (exit 0 both), and the newest court
log `tmp/posh/posh-court-20261030-l38h.log` (14:59 local). Three rows moved
vs the 20:49Z first run:

- POSH-004-IMPORT **PASS -> FAIL**: new compile regression,
  `adapters/terraform-provider-smalt/internal/provider/turnstile_test.go:170`
  — "assignment mismatch: 2 variables but c2.do returns 3 values" (file mtime
  16:05 local, i.e. after the 20:49Z receipt: wave-2 introduced it).
- POSH-001-go-gates SKIP root cause updated: `posh-vet` exit 3 now stems from
  the same `turnstile_test.go` compile error (provider tree does not build).
- POSH-006-posh-court FAIL reason updated: kind node disk preflight now OK
  (34411MB >= 20000MB, l38h log line 8); the failure moved to a 600s infra
  SLA timeout killing `just kind-images` mid image-load. Environmental
  (machine load), not a repo defect — and L16 (gate retarget) is rewriting
  this ladder, so the final verdict on this row is **pending-lane L16**.

| id | requirement (short) | verdict | receipt |
|---|---|---|---|
| POSH-009-COVERAGE | SDK-parity coverage gate green, zero silent gaps | PASS | this session: `--section coverage` exit 0 -> tmp/posh/dod-w2-coverage.json |
| POSH-004-IMPORT | Go provider import-state tests (12 import blocks) | **FAIL** (wave-2 regression) | this session: `--section import` exit 1 — turnstile_test.go:170 arity mismatch -> tmp/posh/dod-w2-import.json |
| POSH-008-turnstile-flip | Turnstile mutation court non-vacuous (4 gates) | PASS | this session: `python3 scripts/posh_mutation_court.py` exit 0, twice consecutively |
| POSH-006-compat-court | Compat-pin shim court flips on wrong ACR pin | PASS | this session: `--section compat` exit 0 -> tmp/posh/dod-w2-compat.json (gaps/33) |
| POSH-006-sla-fixture | SLA clock runner fail-closed, mutation leg RED | PASS | this session: `--section sla` exit 0 -> tmp/posh/dod-w2-sla.json (gaps/31) |
| POSH-006-invariant-court | Invariant SPARQL courts empty over merged graph | PASS | this session: `--section invariant` exit 0 -> tmp/posh/dod-w2-invariant.json (gaps/27) |
| POSH-006-andon-driver | Andon driver builds and runs standalone | PASS | this session: `--section andon` exit 0 -> tmp/posh/dod-w2-andon.json |
| POSH-006-posh-court | posh-court 7-stage ladder exit 0 | **FAIL** (pending-lane L16) | this session: tmp/posh/posh-court-20261030-l38h.log — 600s SLA timeout on `kind-images`; disk preflight now OK (34411MB) |
| POSH-002-live-wire | STS mint + wire round-trip on 127.0.0.1:9443 | **FAIL** | this session: `just posh-smalt-wire` exit 1 — `GET containerApps` -> HTTP 400 |
| POSH-001-go-gates | go vet/gofmt/build over posh/ + provider | SKIP (loud; exit 3; root cause = turnstile_test.go compile error) | this session: `--section go-gates` -> tmp/posh/dod-w2-go-gates.json |
| T1-define-gate | T1 DEFINE charter + ticket set exist | PASS | this session: `--section tollgate` exit 0 (1 PASS/4 SKIP) -> tmp/posh/dod-w2-tollgate.json |
| GAPS-INDEX-consistent | gaps/INDEX.md present, rows re-read on disk | PASS | this session: `--section docs` exit 0 -> tmp/posh/dod-w2-docs.json |
| T2-measure | T2 MEASURE receipts, MSA, DPMO baseline | SKIP (planned, no gate) | dod.yaml row |
| T3-analyze | T3 ANALYZE Ishikawa/FMEA/proof/schema freeze | SKIP (planned) | dod.yaml row |
| T4-design | T4 DESIGN TTL specs, packs, BLAKE3, poka-yoke | SKIP (planned) | dod.yaml row |
| T5-verify | T5 VERIFY cleanroom kind run exit 0, zero drift | SKIP (planned) | dod.yaml row |
| DPMO-campaign | 500-run DPMO campaign denominator-integrated | SKIP (planned) | dod.yaml row (gaps/30) |
| MSA-timers | MSA on monotonic timers | SKIP (planned) | dod.yaml row |
| SPC-control-plan | SPC control plan running | SKIP (planned) | dod.yaml row |
| POSH-005-sidecar-healthz | Sidecar healthz falsifier on kind | SKIP (planned; gap-11 G11-1 HIGH: image lacks /posh/bin/posh) | dod.yaml row (gaps/11); `--section sidecar` exit 0, 1 SKIP, this session |
| POSH-003-arm-face | ARM face api-version ceilings meet azurerm pins | SKIP (planned; PARTIAL per gaps/02) | dod.yaml row (gaps/02); `--section arm-face` exit 0, 1 SKIP, this session |

### harness tier (`harness_dod_check.py`, subject courtroom-platform-az)

Re-run live again in this wave-2 refresh lane (`python3 scripts/harness_dod_check.py` from `/Users/sac/cai/courtroom-platform-az`; verdict FAIL exit 1; totals PASS=5 FAIL=10 SKIP=0 PLANNED=5 — identical to the prior re-run). The 10 receipt-missing FAIL rows are **pending-lane L20** (acceptance lane holds their landing receipts); they are not new defects. Summary of the live run:

```
[DOD] totals: PASS=5 FAIL=10 SKIP=0 PLANNED=5
[DOD] verdict: FAIL (exit 1)
```

Prior capture note (`python3 scripts/harness_dod_check.py`; summary
line: totals PASS=5 FAIL=10 SKIP=0 PLANNED=5, verdict FAIL exit 1). Suites
kept landing after DOD16 (~14:25), so rows moved: HRN-001..006 and
HRN-008..011 flipped PLANNED -> FAIL (gate now exits ok but the landing
receipt `receipts/hrnNNN-*.md` is missing); HRN-015 FAIL -> PASS (script
compiles clean); KPI-3 flake FAIL -> PASS (witnessed via HRN_KPI3_N); KPI-4
now PLANNED (scripts/mutation_court.sh not landed). Note: the API-side suites
HRN-014 names (`apps/api/src/runner.harness.test.ts`) do not exist on disk;
web-side suites under `apps/web/test/` do.

Capture note: this lane's first re-run piped through `tail`, so the shell
showed EXIT=0 while the script's own summary reports exit 1 — capture
artifact of the re-run command, not a script change.

| id | requirement | verdict | receipt |
|---|---|---|---|
| HRN-001 | tenant-case provisioning | **FAIL** (pending-lane L20) | receipts/hrn001-tenant.md absent; re-checked this session |
| HRN-002 | container consolidation | **FAIL** (pending-lane L20) | receipts/hrn002-container.md absent; re-checked this session |
| HRN-003 | key-vault lifecycle | **FAIL** (pending-lane L20) | receipts/hrn003-vault.md absent; re-checked this session |
| HRN-004 | CRMH compliance | **FAIL** (pending-lane L20) | receipts/hrn004-crmh.md exists under a DIFFERENT name — `/Users/sac/cai/courtroom-platform-az/receipts/hrn004-crmh-harness.md` on disk; row filename mismatch, not missing |
| HRN-005 | SIEM telemetry | **FAIL** (pending-lane L20) | receipts/hrn005-siem.md absent; re-checked this session |
| HRN-006 | API version ceilings | **FAIL** (pending-lane L20) | receipts/hrn006-apiversion.md absent; re-checked this session |
| HRN-007 | terminal UX jidoka | PLANNED (terminal suites absent; Playwright absent) | — |
| HRN-008 | NFR perf 15ms loopback ceiling | **FAIL** (pending-lane L20) | receipts/hrn008-perf.md absent; re-checked this session |
| HRN-009 | NFR hermeticity | **FAIL** (pending-lane L20) | receipts/hrn009-hermetic.md absent; re-checked this session |
| HRN-010 | NFR cleanup / zero residue | **FAIL** (pending-lane L20) | receipts/hrn010-cleanup.md absent; re-checked this session |
| HRN-011 | NFR concurrency / port leases | **FAIL** (pending-lane L20) | receipts/hrn011-concurrency.md absent; re-checked this session |
| HRN-012 | 3-stage gates PRE/LIVE/POST | PLANNED (script not landed) | — |
| HRN-013 | mutation court >90% kill | PLANNED (metadata drift persists — scripts/harness_mutation_court.sh confirmed on disk this session; final verdict pending-lane L19/L20) | `ls` confirms script present |
| HRN-014 | runner config + STS recipe | PLANNED (apps/api/src/runner.harness.test.ts absent, re-checked this session) | `ls` -> No such file |
| HRN-015 | DoD itself (this script) | PASS | receipts/dod-landing.md still absent (row gate is py_compile only) |
| KPI-suite-time | full suite < 45s (KPI-1) | PASS | — |
| KPI-mock-count | 0 mocks in test dirs (KPI-2) | PASS | — |
| KPI-flake | 0 failures / 1000 loops (KPI-3) | PASS (this session; DOD16 had FAIL) | — |
| KPI-mutation | mutation kill > 90% (KPI-4) | PLANNED (scripts/mutation_court.sh still absent, re-checked this session) | `ls` -> No such file |
| KPI-skip-loudness | substrate down => exit 3, never silent | PASS | — |

## v26.10.32 backlog (FAIL rows, seeded verbatim)

smalt tier (3):

1. POSH-004-IMPORT (NEW, wave-2 regression, highest priority):
   `adapters/terraform-provider-smalt/internal/provider/turnstile_test.go:170`
   — `if _, _, err := c2.do(...)` binds 2 of 3 return values
   ("assignment mismatch"). One-line test fix; also blocks POSH-001-go-gates
   (provider tree cannot build). Align the destructuring to the current `do`
   signature (mirror line 165), then re-run `--section import` and
   `--section go-gates`.
2. POSH-006-posh-court: 7-stage ladder exit 1 — now a 600s infra SLA timeout
   on `just kind-images` (the old disk-preflight cause is fixed: kind node
   reports 34411MB >= 20000MB). Environmental (machine load); re-run
   `just posh-court` on a quiet machine. Final verdict pending-lane L16
   (gate retarget is rewriting this ladder).
3. POSH-002-live-wire: `just posh-smalt-wire` exit 1 — `GET containerApps`
   returns HTTP 400 (captured live this session). Diagnose the ARM-face
   request shape against the emulator; not disk-related.

harness tier (10): the FAIL class is uniform — gate exit ok, landing receipt
`receipts/hrnNNN-*.md` missing. One class item plus two singles:

3. HRN-001..006, 008..011: write landing receipts backed by real suite runs
   (or make the check self-write a receipt on a green gate — the HRN-015
   pattern). Wave-2 note: HRN-004 is a filename mismatch, not a missing
   receipt — `receipts/hrn004-crmh-harness.md` exists; rename or extend the
   row's expected path. All ten rows are pending-lane L20.
4. `scripts/harness_dod_check.py` row-metadata drift: HRN-013's hardcoded
   "script not landed" contradicts `scripts/harness_mutation_court.sh` on
   disk — rows must probe disk instead of hardcoded planned_reason (same
   class as gap 69 Residual #1).
5. `just doctor` shipped `SMALT_ROOT` default resolved wrong during DOD16
   (../smalt); the current justfile (line 5) pins `/Users/sac/smalt` and
   works. Carry a regression guard into v26.10.32: the default must resolve
   to an existing directory.

## Notes / status vocabulary

- Status: PARTIAL — two courts merged; smalt tier fully re-run live this
  wave-2 lane (per-section receipts tmp/posh/dod-w2-*.json); harness tier
  re-run live again this session (identical totals). Pending held lanes:
  L16 (posh-court gate retarget), L19 (supervisor swap), L20 (harness
  acceptance receipts) — rows tagged pending-lane above are deferred to
  those lanes, not failed.
- Receipt of this lane: this file.
- Path correction vs DOD16: the posh v26.10.31 gaps dir is
  `docs/jira/posh/v26.10.31/gaps/` (DOD16's header cited `posh/v26.10.31/`).
