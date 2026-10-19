# Just Reference

Complete ops surface for the smalt repository via `just`. Every recipe is
self-documenting: `just --list` shows descriptions. Canonical checkout:
`~/smalt`.

Entry point: `just` (no args) runs `doctor test-native` — quick preflight +
native test tier. The full admission gate is `just court`.

## Recipes

| Recipe | What it runs | Exit-code contract | Typical latency |
|---|---|---|---|
| `default` | `doctor test-native` (quick preflight + native tier) | doctor: 0 healthy / 1 finding; test-native: 0 pass / nonzero fail | ~1-3m |
| `test-native` | `justfile.d/22-native.just` — native enclave lifecycle test (Hcl parse → Engine apply → State.plan zero-drift → State.destroy; private ports 29445-29450) | 0 pass / nonzero fail | see `just test-native` |
| `doctor` | `python3 scripts/doctor.py` — runtime preflight (deps, ports, certs, toolchain) | 0 healthy / 1 finding | ~2s |
| `status` | Inline: smalt beams (pgrep), listening ports 9443/9444/5672/5673 (lsof), 5 newest `tmp/*receipt*.json` summaries | 0 always (report-only; safe with no substrate) | ~1s |
| `logs` | `tail -f` newest `tmp/*.log` | 0 while following / 1 if no logs exist | follows |
| `receipts` | `ls -lt tmp/*receipt*.json \| head -15` | 0 always | <1s |
| `up` | `mix run --no-halt` (pid written to `/tmp/smalt.pid`) | 0 while running; Ctrl-C stops | blocking |
| `down` | `kill $(cat /tmp/smalt.pid)`, removes pid file | 0 always (idempotent) | <1s |
| `clean` | Kill stray smalt beams (beam.smp matching "smalt"), `rm -rf _build-lane*`, `rm erl_crash.dump tmp/*.log` | 0 always; never touches `_build/` or `deps/` | ~1s |
| `gen` | `mix smalt.gen` | 0 on success | seconds |
| `test-offline` | `mix test` (T1, residual tier `test/internal/` post-reset) | 0 pass / nonzero fail | 1-3m |
| `test-wire` | RETIRED@64f6099 (loud exit-1 placeholder; `test/wire` deleted) | successor: `verification/ts` (V261019-08) | — |
| `test-sdk-smoke` | RETIRED@64f6099 (loud exit-1 placeholder; `test/sdk-smoke/` deleted) | successor: `verification/{ts,py}` (V261019-08/09) | — |
| `eh-smoke` | RETIRED@64f6099 (loud exit-1 placeholder) | successor: `verification/ts` EH probes | — |
| `census` | RETIRED@64f6099 (loud exit-1 placeholder; `scripts/sb_census_replay.sh` is a loud no-op) | successor: `verification/ts` census probes | — |
| `sdk-ts` / `sdk-census` / `sdk-py` / `sdk-all` | RETIRED@64f6099 loud exit-1 placeholders (`justfile.d/04-sdk-recipes.just`) | successors: `verification/ts` (V261019-08) / `verification/py` (V261019-09) | — |
| `mutation-court` | `python3 scripts/mutation_court.py` (validator-gate non-vacuity proof) | 0 non-vacuous / 1 vacuous / 2 BLOCKED (compile broken) | ~3-5m |
| `tf-plan-smoke` | `bash scripts/tf_smoke.sh` (T4, terraform fixture plan) | 0 pass / 1 preflight or substrate failure / 2 terraform step failure / 77 SKIPPED-NETWORK (registry unreachable; court fails — rerun online) | <1m |
| `bench` | `python3 scripts/bench.py` (boots substrate; writes `tmp/bench-receipt.json`; fixed ports 9443/8443/5672 — if they are held, set `SMALT_BENCH_{ARM,DATA,AMQP}_PORT` to a port from the documented private range 39000-39999 (docs/how-to/dev-loop.md "Private port allocation") or let bench auto-pick an ephemeral block; same functions, same receipt schema, chosen ports recorded in the receipt. Exit contract: 0 only when all 5 CTQ verdicts PASS; any FAIL → typed `GATE: FAIL (…)` + exit 1) | 0 complete + 5/5 CTQs / nonzero fail | 2-5m |
| `bench-check` | `python3 scripts/bench_check.py` (CTQ gate over `tmp/bench-receipt.json`) | 0 all CTQs pass / 1 missing/stale/failing receipt | ~1s |
| `soak` | `python3 scripts/stress/soak.py` (25 min mixed traffic at 50 rps) | 0 pass / nonzero on any 5xx, RSS growth >20% after min 5, or error | ~25m |
| `spike` | `python3 scripts/stress/spike.py` (500-concurrent spike, recovery, TLS herd) | 0 pass / nonzero fail | 5-10m |
| `tls-churn` | `python3 scripts/stress/tls_churn.py` (handshake churn vs 9444 TLS twin) | 0 pass / nonzero if any scenario cannot complete | 2-5m |
| `court` | `doctor test-offline tf-plan-smoke bench-check mutation-court census invariant-gates naming-sweep verification-gates` (9 members; `census` is a RETIRED exit-1 placeholder until the verification/ts census lands) | 0 only when every court passes | ~5-15m |
| `gate` | Alias for `court` (legacy name, kept for compat) | same as `court` | see `court` |

## Conventions

- Every wrapper recipe invokes the landed script; no logic is duplicated here.
- Exit codes of wrapped scripts pass through unchanged.
- `status`, `receipts`, `clean`, `down` are safe to run with no substrate.
- Stress recipes (`soak`, `spike`, `tls-churn`, `bench`, `mutation-court`)
  boot and kill their own substrates — do not run two concurrently (port
  contention on 9443/9444/5672/5673).

## justfile.d modules

The root `justfile` is a thin aggregator: it defines `default`
(`doctor test-native`) plus the core recipes above, then imports every
module. Lanes ADD
modules (`justfile.d/NN-*.just` + one `import` line in the root); they never
edit the root or each other's modules — concurrent lanes editing one file
collide. Current: 31 modules, numbering 01..32 with 16 and 17 unoccupied
(`ls justfile.d/*.just | wc -l`, 2026-10-19).

- `01-substrate-lock.just` — `substrate-up/down/status`: per-window flock
  substrate manager; lock held only while spawning + verifying (the beam is
  launched with the lock fd closed). Exit 0 up / 2 boot fail / 3 lock
  not acquired.
- `02-workspace.just` — `ws-install/build/lint/court/converge`: Next.js
  workspace gates (`ws := join(justfile_directory(), "workspace")`).
- `03-cli-wiring.just` — smalt-cli pytest lanes over two venvs (`.venv`,
  `.venv-cli`); cli-gate1 drives `run_gate1` directly with `.venvs/<lane>`
  symlinks (ADR-PY-002).
- `04-sdk-recipes.just` — `sdk-ts/census/py/all`: RETIRED@64f6099 loud
  exit-1 placeholders (subjects deleted); successors `verification/ts`
  (V261019-08) / `verification/py` (V261019-09). Exit contracts to restore
  on repoint are documented in the module header.
- `32-verification.just` — `non-duplication-gate` / `portable-target-gate`
  / `verification-gates` / `verification-courts`: post-reset verification
  governance gates over `test/internal/` + `verification/`.
- `05-doctor-ext.just` — `doctor-dod`: supplemental DoD doctor pass
  (`DOD5_ROOT :=`); non-fatal INFO/WARN, hard FAIL on DoD violations.
- `06-lane-cleanup.just` — `lane-clean[-dry]`: deletes orphaned `_build*`
  lane lease dirs (lsof-guarded); canonical `_build` is never touched.
- `07-court-x2.just` — `court-x2`: the full admission court twice
  consecutively; two fresh greens are the release receipt.
- `08-publish-dry.just` — `publish-dry`: hex tarball gates (inner-tar key
  grep, packaged-set leak grep, ERROR_CODES regen identity).
- `09-verify-all.just` — `verify-all`: offline stages only (doctor,
  doctor-dod, test-offline, ws-court, cli pytest, naming-sweep,
  invariant-gates), per-stage verdict table.
- `10-gap-register-sync.just` — `gap-sync`: re-runs the audit greps and
  diffs the gap/defect register against the census; exit 1 on drift.
- `11-relay-env.just` — `relay-env`: canonical loopback session env block
  (`eval "$(just relay-env)"`).
- `12-docs-dod.just` — `docs-dod-check`: every receipt path named in
  user-facing docs must exist on disk.
- `13-receipt-index.just` — `receipt-index[-check]`: regenerate RECEIPTS.md
  + receipts/INDEX.md; the check diffs one regen against committed bytes.
- `14-sdk-matrix.just` — `sdk-matrix[-md]`: SDK coverage matrix compiler;
  exit 0 only when every cell is pass-or-registered.
- `15-bench.just` — `bench-machine` / `bench-report`: machine-spec block +
  aggregation of bench JSONL into BENCH_RESULTS.md.
- `18-shim-court.just` — `shim-court <name>` / `shim-courts`: reusable
  shim-court harness (protocol: `scripts/shim_court/README.md`).
- `19-wave-telemetry.just` — `wave-report`: per-lane wall-clock/wait table
  from `bench/wave-telemetry.jsonl`; empty-state honest.
- `20-sobelow.just` — `sobelow`: static security scan over lib/
  (non-blocking first pass; triage pointer printed).

### Shebang recipe rule (rule 5, fan-out law)

Shebang (`#!/usr/bin/env bash`) recipes run in a child shell, where
`justfile_directory()` interpolation breaks on just 1.56. Bind any path the
body needs as a module-scope `:=` variable (module-prefixed: `GAP_SYNC_ROOT`,
`DOD5_ROOT`, `DOCS_ROOT`) and interpolate `{{VAR}}` inside the shebang body.
Canonical fix: `10-gap-register-sync.just` binds
`GAP_SYNC_ROOT := justfile_directory()` at module scope so `gap-sync`'s
shebang body reads `REPO="{{GAP_SYNC_ROOT}}"` instead of calling
`justfile_directory()` mid-script.

## See Also

- `docs/how-to/dev-loop.md` (iteration loop, private port table)
- `docs/reference/just-recipes.md` (Diátaxis just reference home)
