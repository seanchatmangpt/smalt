# SCVD-T9 — `just scvd-ramp` one-command tier runner

**Standing:** **ALIVE** (live-substrate full ramp PASS exit 0; down/skip/fail paths exercised with typed exits)

Date: 2026-10-21 · Repo: /Users/sac/smalt · Lane: SCVD-T9 (writer)

## Files (owned by this lane)

- `scripts/scvd_ramp.sh` — new. Runner: preflight probe → tier dispatch → jsonl aggregation.
- `justfile.d/43-scvd.just` — new module, prefixed vars (`SCVD_ROOT`), one import line added to root `justfile`.
- `justfile` — one import line only (`# 43-scvd — SCVD tier runner (SCVD-T9)` + `import 'justfile.d/43-scvd.just'`).

## Contract

`just scvd-ramp [tier1|tier2|tier3|all]` (default all).
Boots NOTHING: preflight probes ARM 9443 + data 8443; unreachable → loud exit 2.
Exit codes: 0 pass / 1 tier fail / 2 substrate down / 3 skip (all tiers missing = 3).
Missing harness = loud SKIP, never a faked pass.
Aggregates `tmp/bench/scvd-*.jsonl` (latest line per file) into a stdout table.
Env seams (test only, all default to production values): `SCVD_ARM`, `SCVD_DATA`,
`SCVD_T{1,2,3}_SCRIPT`, `SCVD_QUIET`.

## Fixed during the run (session-introduced, disclosed)

1. `root :=` collided with `justfile.d/31-have.just` at parse — per-module prefix
   law applied (`SCVD_ROOT`). The prompt-suggested
   `parent_directory(justfile_directory())` resolved wrong in an imported module
   (gave `/Users/sac`) — `justfile_directory()` is already the repo root for
   imports; used that instead.
2. First verdict-capture design put harness stdout into `$(...)` and garbled
   verdicts — rewritten to a mktemp verdict file.
3. tier1 rides the 9444 TLS twin and fails with `UNABLE_TO_VERIFY_LEAF_SIGNATURE`
   without the dev CA (harness-owned behavior, pre-existing for bare `node` runs;
   T1's earlier PASS receipts ran with the CA env). Runner now defaults
   `NODE_EXTRA_CA_CERTS=$ROOT/.smalt/tls/ca-cert.pem` when unset (respects caller env).

## Tier1 TLS fail before the CA default (pre-fix run, exit 1 — honest record)

```
RestError: unable to verify the first certificate; ... {
  code: 'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
```
Runner verdict: `verdicts: tier1=FAIL tier2=PASS tier3=PASS (ran=2 skipped=0 failed=1)` → exit 1.

## Run: full ramp against LIVE substrate (exit 0)

```
[SCVD-RAMP] preflight: ARM=http://127.0.0.1:9443 data=http://127.0.0.1:8443
[SCVD-RAMP] substrate reachable.
2026-10-21T17:49:24.598Z level 2048: n=16384 ops/s=1008.7 p50=1542.348ms p95=4575.117ms p99=5951.561ms errors=0 degraded=false
2026-10-21T17:49:24.598Z WALL=unreached typedFail512=false totalMs=25994

[SCVD-RAMP] SCVD ramp table (latest line per tmp/bench/scvd-*.jsonl):
LANE                N      OPS/SEC     P50_MS     P99_MS  ERRORS          VERDICT
scvd-t12          512       1196.3     92.749    206.636       0                -
scvd-chaos-c     2000         1218          -          -       0             PASS
scvd-t4             -            -          -          -       - INVARIANCE-BREACH
scvd-t1           160       2267.2      5.941      18.72       0             PASS
scvd-tier2       1024       2381.4     44.345    134.828       0                -
scvd-tier3          0            0          0          0       0                -
scvd-wasm-vs        3            -          -          -       0    PARTIAL_ALIVE

[SCVD-RAMP] verdicts: tier1=PASS tier2=PASS tier3=PASS (ran=3 skipped=0 failed=0)
[SCVD-RAMP] PASS
EXIT=0
```

(Pre-existing `scvd-t4 INVARIANCE-BREACH` / `scvd-wasm-vs PARTIAL_ALIVE` rows are
other lanes' jsonl tails, aggregated verbatim — not this lane's verdict.)

Single-tier: `bash scripts/scvd_ramp.sh tier1` → `verdicts: tier1=PASS (ran=1 ...)` exit 0.

## Negative paths

Substrate down (bad port env override, boots/stops nothing):
```
SCVD_ARM=http://127.0.0.1:1 SCVD_DATA=http://127.0.0.1:1 bash scripts/scvd_ramp.sh all
[SCVD-RAMP] FAIL: ARM endpoint http://127.0.0.1:1 unreachable — substrate DOWN (exit 2). ...
EXIT=2
```
All-harnesses-missing skip:
```
[SCVD-RAMP] SKIP(scvd-t1): harness missing: /nonexistent/scvd_tier1.mjs (loud skip, never a faked pass)
[SCVD-RAMP] verdicts: tier1=SKIP tier2=SKIP tier3=SKIP (ran=0 skipped=3 failed=0)
[SCVD-RAMP] SKIP: no tier ran (all missing) (exit 3)
EXIT=3
```
Post-run substrate still up: `arm9443=401 data8443=401`.

## Machine

`just bench-machine` →
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Falsifiers

- Re-run with substrate stopped → exit 2 (verified via port override; direct stop not exercised, stop-nothing law).
- Rename any tier harness → loud SKIP; all three missing → exit 3 (verified via script-path overrides).
- Inject a tier failure → exit 1 (observed live pre-CA-fix, tier1 TLS fail).
