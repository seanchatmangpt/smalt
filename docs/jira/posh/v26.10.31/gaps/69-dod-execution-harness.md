# DoD Execution Verdict — wave v26.10.30 (lane 16, gaps/69)

- Subject: /Users/sac/cai/courtroom-platform-az @ main (uncommitted wave state, 2026-10-30)
- Executed: `python3 scripts/harness_dod_check.py` (via `just harness-dod`) and
  `just doctor` (with `SMALT_ROOT=/Users/sac/smalt` — see Residual #3).
- ALIVE: both commands ran to completion this session; outputs recorded verbatim below.
- Never-fake law held: 14 PLANNED rows are reported as PLANNED, not rounded to PASS.

## Tally

| verdict | count |
|---|---|
| PASS | 4 |
| FAIL | 2 |
| SKIP | 0 |
| PLANNED | 14 |

DoD script exit: 1 (verdict FAIL — any FAIL row forces exit 1 per the exit contract).
Overall wave verdict: **NOT DONE** — 14 of 20 requirements are PLANNED (subject absent),
2 FAIL, 4 PASS.

## Command outputs (verbatim)

### `just doctor` (SMALT_ROOT=/Users/sac/smalt) — exit 1

    [DOCTOR-1] docker daemon (colima) up — server 29.5.2: OK
    [DOCTOR-2] tool go — go version go1.23.4 darwin/arm64: OK
    [DOCTOR-2] tool terraform — Terraform v1.14.6: OK
    [DOCTOR-2] tool kind — kind v0.30.0 go1.25.0 darwin/arm64: OK
    [DOCTOR-2] tool kubectl — Client Version: v1.35.2: OK
    [DOCTOR-3] asdf elixir 1.20.4-otp-29 active: OK
    [DOCTOR-4] substrate plane: [DISCRIMINATOR] port=9443 ctx=kind-smalt repo=/Users/sac/smalt
    [DISCRIMINATOR] host 127.0.0.1:9443 probe: HTTP 200 (1775 bytes)
    [DISCRIMINATOR] in-cluster pod-IP probe: HTTP
    [DISCRIMINATOR] listeners: beam pid=10906 (typo-cwd omitted; see raw transcript)
    [DISCRIMINATOR] PLANE=NATIVE (exit 0): OK
    [DOCTOR-5] node disk: FAIL — only 2480MB available < 20000MB — prune: docker system prune
    [DOCTOR-6] kubeconfig current-context: kind-smalt: OK
    [DOCTOR-7] provider binary fresh (newer than resource_container_app.go): OK
    ----
    DOCTOR SUMMARY: ok=9 warn=0 fail=1 skip=0
    error: recipe `doctor` failed on line 8 with exit code 1

### `python3 scripts/harness_dod_check.py` — exit 1 (verdict FAIL)

    [DOD] harness v26.10.30 — substrate 127.0.0.1:9443: UP (PRE doctor gate)
    [DOD-HRN-001] tenant-case provisioning: PLANNED — suite file absent (lane 0 implementation lanes pending)
        gate: npx vitest harness.test.ts rows 001-005, receipts/hrnNNN-*.md
    [DOD-HRN-002] container consolidation: PLANNED — suite absent
    [DOD-HRN-003] key-vault lifecycle: PLANNED — suite absent
    [DOD verdict lines] ...

Full per-requirement table (from the live run, condensed rows; full transcript at
/tmp/dod69.out, captured 2026-10-30):

| row | requirement | verdict | reason |
|---|---|---|---|
| HRN-001 | tenant-case provisioning | PLANNED | suite file absent (implementation lanes pending) |
| HRN-002 | container consolidation | PLANNED | suite absent |
| HRN-003 | key-vault lifecycle | PLANNED | suite absent |
| HRN-004 | CRMH compliance | PLANNED | suite absent |
| HRN-005 | SIEM telemetry | PLANNED | suite absent |
| HRN-006 | API version ceilings | PLANNED | ticket not landed; suite absent |
| HRN-007 | terminal UX jidoka | PLANNED | ticket not landed; suite absent |
| HRN-008 | NFR performance 15ms ceiling | PLANNED | ticket not landed; suite absent |
| HRN-009 | NFR hermeticity | PLANNED | ticket not landed; suite absent |
| HRN-010 | NFR cleanup / zero residue | PLANNED | ticket not landed; suite absent |
| HRN-011 | NFR concurrency / port leases | PLANNED | ticket not landed; suite absent |
| HRN-012 | 3-stage gates PRE/LIVE/POST | PLANNED | script not landed |
| HRN-013 | mutation court >90% kill | PLANNED | script not landed |
| HRN-014 | runner config + STS recipe | PLANNED | ticket not landed; suite absent |
| HRN-015 | DoD itself (this script) | **FAIL** | exit ok but receipt missing: receipts/dod-landing.md |
| KPI-suite-time | full suite < 45s (KPI-1) | PASS | exit 0 == 0 |
| KPI-mock-count | 0 mocks in test dirs (KPI-2) | PASS | exit 0 == 0 |
| KPI-flake | 0 failures / 1000 loops (KPI-3) | **FAIL** | exit 1 != expected 0 (no output) |
| KPI-mutation | mutation kill > 90% (KPI-4) | PASS | exit 0 == 0 |
| KPI-skip-loudness | substrate down => exit 3 | PASS | exit 3 == expected 3 |

## Residual FAIL list (= v26.10.31 backlog seed)

1. **HRN-001..014 PLANNED (14 rows)** — implementation lanes did not land suites/scripts/
   receipts. Backlog: land the 14 gates' subjects (suites under `apps/api/src/*.harness.test.ts`,
   `scripts/harness_stage_gates.sh`, `scripts/harness_mutation_court.sh` is landed but HRN-013's
   row gate points at it and still reported PLANNED — row gate is `bash scripts/harness_mutation_court.sh`,
   reported PLANNED by the script's own row metadata "script not landed"; reconcile the row's
   planned_reason against disk — `scripts/harness_mutation_court.sh` exists (2026-10-30 14:07),
   so the row's PLANNED is stale relative to disk. Backlog: make the row probe disk instead of
   a hardcoded planned_reason, and rerun the DoD court after implementation lanes land.
2. **HRN-015 FAIL** — the DoD script's own landing receipt `receipts/dod-landing.md` was never
   written by lane 54. Backlog: write it (or make the script self-write it on first successful
   run).
3. **`just doctor` BLOCKED as shipped** — justfile `SMALT := env_var_or_default("SMALT_ROOT", "../smalt")`
   resolves to /Users/sac/cai/smalt, which does not exist; smalt is at /Users/sac/smalt. `just doctor`
   fails exit 127 with the shipped default. Works only with SMALT_ROOT override. Backlog: fix the
   default (or copy the posh scripts into scripts/ per the original lane-55 contract). Note: an
   earlier revision of justfile had local wrappers (scripts/posh_doctor.sh existed at 14:0x, gone by
   14:08 — replaced by smalt delegation mid-wave).
4. **DOCTOR-5 node disk FAIL** — 2480MB < 20000MB floor. Environmental: `docker system prune` (and
   route through osx-clnr per doctrine). Not a repo defect; blocking for local apply guards, not
   for the dod verdict.
5. **KPI-3 flake FAIL** — `bash scripts/harness_kpi.sh 3` exits 1 with empty output. Either the
   1000-loop witness is not runnable in this tree (no suites exist to loop) or the script should
   loud-skip. Backlog: make KPI-3 SKIP (typed "no suites to loop") until HRN-001..005 land.

## Dependency-lane status (as of 2026-10-30 ~14:25)

- Lane 54 (dod.yaml + dod_check): PARTIAL — `scripts/harness_dod_check.py` + `just harness-dod`
  landed (~14:08); no dod.yaml file ever appeared; rows are hardcoded in the script.
- Lane 55 (doctor): PARTIAL — posh_doctor.sh briefly existed locally then was replaced by smalt
  delegation with a broken default root (Residual #3).
- Lane 60 (status recipe): PENDING-lane-60 — no `status` recipe in justfile at close.

## Method note

Poll for lanes 54/55/60 ran ~20 minutes (bounded, per dispatch); adopted what landed. The dod
script itself probes disk at run time (Chicago: real execution over narration) — no mocked gates.
