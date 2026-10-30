# 54-dod-manifest

DoD single source for the POSH v26.10.30 wave: `dod.yaml` at the repo root +
reader `scripts/dod_check.py` + entry `just dod` / `just dod-section <name>`.
Lane 1, 2026-10-30.

## What landed

- `dod.yaml` — 21 requirement rows; every ALIVE claim of the wave as
  (id, section, claim, gate, expected_exit, receipt, status). 12 rows
  status: alive (each with a real gate command), 9 rows status: planned
  (DPMO campaign, MSA, SPC control plan, sidecar healthz falsifier,
  provider court, tollgates T2-T5). Planned rows carry NO gate command —
  they read SKIP loudly, never ALIVE.
- `scripts/dod_check.py` — parses dod.yaml, runs each status:alive gate
  timeout-bounded (default 600s, --timeout override), compares exit to
  expected_exit, prints per-requirement PASS/SKIP/FAIL with the gate's own
  typed last line, `--section` filter, `--json-out` machine results.
  Exit contract: 0 iff no FAIL among status:alive rows; gate exit 3 = loud
  SKIP with the gate's typed reason (substrate down, tool missing); status:
  planned = loud SKIP "planned (no gate registered)".
- `justfile.d/60-dod.just` + one import line in the root `Justfile` —
  `just dod`, `just dod-section <section>`; results JSON at
  `tmp/posh/dod-latest.json`.

## First real run (recorded verbatim, 2026-10-30)

Invocation: `python3 scripts/dod_check.py --json-out tmp/posh/dod-first-run.json`

```
PASS  POSH-009-COVERAGE            [POSH-COVERAGE] SUCCESS: 100% surface coverage with zero silent gaps.
PASS  POSH-004-IMPORT              ok  	terraform-provider-smalt/internal/provider	0.281s
PASS  POSH-008-turnstile-flip      === POSH ADMISSION MUTATION COURT: ALL 4 GATES PROVEN NON-VACUOUS (ALIVE) ===
PASS  POSH-006-compat-court        [COMPAT-COURT] PASS: wrong pin (ACR 2024-03-01) flipped gate to exit 1; real pin byte-identical
PASS  POSH-006-sla-fixture         [SLA-RED] sla-fixture-sleep exceeded 5s — killed, RED (timeout counts as fail)
PASS  POSH-006-invariant-court     [POSH-INV-COURT] PASS gate flipped exit 1 naming invariant_orphan_route.rq / routeOrphanInjected
PASS  POSH-006-andon-driver        ok  	smalt.dev/posh/cmd/andon	0.240s
FAIL  POSH-006-posh-court          exit 1 != expected 0: error: recipe `posh-court` failed with exit code 1
FAIL  POSH-002-live-wire           exit 1 != expected 0 (see below — containerApps GET 400)
FAIL  POSH-001-go-gates            exit 3 (loud SKIP) — golangci-lint not on PATH
PASS  T1-define-gate               exit 0
PASS  GAPS-INDEX-consistent        exit 0
SKIP  T2..T5, DPMO, MSA, SPC, sidecar-healthz, arm-face — planned (no gate registered)
```

Summary: **9 PASS / 2 FAIL / 10 SKIP — exit 1** (honest baseline, not a
defect of the reader). Machine copy: `tmp/posh/dod-first-run.json`.

## Honest-baseline FAILs (both pre-existing, not session-introduced)

- `POSH-006-posh-court` — standing receipt is FAIL 0/8 (kind node disk
  preflight: 14756MB < 20000MB on smalt-control-plane:/var/lib/containerd;
  receipts/posh-court/posh-court-green.json, lane F3). Unchanged by this
  lane; flip requires the disk-residue cleanup (gaps/37 ledger).
- `POSH-002-live-wire` — substrate IS answering at 127.0.0.1:9443, but
  `GET /subscriptions/.../containerApps` returns 400, so the stage-5 wire
  assert fails fail-closed (exit 1). Live state divergence at run time;
  pre-existing relative to this lane.

SKIP-with-reason leg: `POSH-001-go-gates` ran `just posh-build` green then
`just posh-vet` exited 3 — "[POSH-VET-SKIP] golangci-lint not on PATH —
install: brew install golangci-lint; loud skip". Reader reports SKIP loud
with that reason; not a silent pass.

## Gates

- `python3 scripts/dod_check.py` — ran end-to-end: exit 1 with 2 alive-row
  FAILs honestly recorded (0 iff no alive FAIL; falsifier: an alive row
  failing while the reader exits 0).
- `just --evaluate` — exit 0.
- `just dod` — exit 1 (mirrors the reader's honest baseline).
- `just dod-section docs` — exit 0 (1 PASS / 0 FAIL).

## Notes

- One mid-run freeze window: `just` failed to parse `justfile.d/58-posh.just`
  during my first dod_check pass (inconsistent leading whitespace at a
  bootstrap lane's in-flight line; parse error at `not_in_loop`, line 1025).
  The owning lane fixed its own file within minutes; no fix applied by this
  lane. `just --evaluate` re-verified exit 0 afterward. Disclosed per the
  compile-freeze SLA — zero unblocks applied here.
- 58-posh.just was NOT modified by this lane (actively lane-owned). This
  lane's just surface is `justfile.d/60-dod.just` + the single import line.
