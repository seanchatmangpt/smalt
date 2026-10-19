# just-recipes

Every recipe on the `just` CLI surface, by source module. Projected from
`just --list` and the module files themselves; regenerate by re-reading the
modules, do not hand-patch this table.

Module inventory (as of 2026-10-19 @ HEAD 6681746): 29 modules in
`justfile.d/` (01-15, 18-30; slots 16-17 do not exist; 28 is shared by
28-stress and 28-test-budget) plus the root `Justfile` for core
substrate/court recipes. Naming convention: `NN-<concern>.just`, one import
line each in the root `Justfile` (lines 221-254); concurrent lanes add
modules, never edit the root.

## Root Justfile (core substrate + admission courts)

| recipe | one-line | notes |
|---|---|---|
| `default` | lists recipes | section-sorted listing |
| `doctor` | preflight: deps/ports/certs/toolchain | exit 0/1; ~2s |
| `status` | report-only: beams, ports, latest tmp receipts | exit 0 always |
| `logs` | tail newest `tmp/*.log` | follow mode |
| `receipts` | list recent court/bench/stress receipts (top 15) | exit 0 always |
| `up` | boot substrate, FOREGROUND, pid in /tmp/smalt.pid | global collision point; lanes use substrate-up |
| `down` | stop substrate via pid file, idempotent | exit 0 either way |
| `clean` | remove tmp logs | never touches `_build/`/`deps/` |
| `gen` | `mix smalt.gen` code projections | byte-identical replay test-fenced |
| `test-offline` | T1 offline unit suite (`mix test`) | ~1-3m |
| `test-wire` | T2 wire tier (`mix test test/wire`) | |
| `test-sdk-smoke` | node test/sdk-smoke/run.mjs | boots own substrate; 0/1/2/3 exit contract |
| `tf-plan-smoke` | terraform plan-parse smoke over six fixtures | |
| `eh-smoke` | Event Hubs probe | 0 pass / 1 fail / 2 substrate down / 3 skip |
| `census` | SB census replay (scripts/sb_census_replay.sh, 8 probes, real SDK) | 0/1/2/3 |
| `mutation-court` | anti-vacuity mutation court | part of `court`; do not soften |
| `invariant-gates` | 6 fail-closed gates (cosmos-etag-cas, blob-worm, ledger-chain, queue-capacity, lock-clamp, appconfig-etag-cas) | receipts `tmp/invariant-gates/<gate>-receipt.json` (6, written fresh) |
| `naming-sweep` | naming/egress leak sweep | 0 clean / 1 violations printed |
| `gen-error-codes` | regenerate docs/ERROR_CODES.md | drift-fenced `--check` |
| `bench` | bench runner, writes tmp/bench-receipt.json | 0 all CTQs PASS / nonzero; `SMALT_BENCH_{ARM,DATA,AMQP}_PORT` for private ports |
| `bench-check` | validate CTQ receipt freshness | ~1s |
| `soak` | long-run soak, fails on 5xx / >20% RSS growth | ~25m |
| `spike` | recovery-cycle spike | ~5-10m |
| `tls-churn` | TLS churn scenarios, fail-closed | ~2-5m |
| `court` | full admission court | doctor + tiers + tf smoke + bench-check + mutation-court + census + invariant-gates + naming-sweep |
| `gate` | alias for `court` | legacy name |
| `bootstrap` | zero-to-green first run | 8 idempotent stages, exit 2 prints brew installs |

## justfile.d modules

| module | recipe | one-line |
|---|---|---|
| 01-substrate-lock | `substrate-up` | flock-managed boot; 0 up / 2 boot fail / 3 lock not acquired |
| 01-substrate-lock | `substrate-down` | release lock, verify ports free; 0 free / 1 still held |
| 01-substrate-lock | `substrate-status` | report-only lock/orphan status |
| 02-workspace | `ws-install` | npm ci (lockfile present) else npm install |
| 02-workspace | `ws-build` | Next.js workspace build |
| 02-workspace | `ws-lint` | ESLint (raw-fetch ban, smaltFetch-only egress) |
| 02-workspace | `ws-court` | workspace e2e court (workspace/scripts/e2e-court.mjs) |
| 02-workspace | `ws-converge` | ws-court + converge, exports court exit code |
| 03-cli-wiring | `cli-test` | smalt-cli pytest over `.venv-cli` (the only real venv; `.venvs/<lane>` symlinks satisfy per-lane resolution — a bare `.venv` does not exist and is never created, ADR-PY-002) |
| 03-cli-wiring | `cli-gates` | CLI invariant gates |
| 03-cli-wiring | `cli-gate1`..`cli-gate4` | individual CLI gate tiers |
| 03-cli-wiring | `cli-daemon` | CLI daemon mode |
| 03-cli-wiring | `cli-smoke` | CLI smoke probe |
| 04-sdk-recipes | `sdk-ts` / `sdk-py` / `sdk-census` / `sdk-all` | real-Azure-SDK probes; 0 pass / 1 fail / 2 substrate down / 3 SKIP |
| 05-doctor-ext | `doctor-dod` | supplemental DoD doctor; FAIL on DoD violations |
| 06-lane-cleanup | `lane-clean` / `lane-clean-dry` | delete every repo-root `_build*` dir except the canonical `_build`, skipping live-referenced roots (lsof/ps `MIX_BUILD_ROOT` harvest); dry run lists with `du -sh` |
| 07-court-x2 | `court-x2` | two-green release gate, flake signature between runs; ~8 min |
| 08-publish-dry | `publish-dry` | publish gates dry-run (tarball leak greps, ERROR_CODES identity) |
| 09-verify-all | `verify-all` | offline stages only: doctor, test-offline, ws-court, cli pytest, naming-sweep, invariant-gates |
| 10-gap-register-sync | `gap-sync` | re-run audit greps, diff gap register vs lane-13 census; exit 1 on drift |
| 11-relay-env | `relay-env` | print/exports canonical relay session env (loopback only) |
| 12-docs-dod | `docs-dod-check` | every receipt path named in docs exists on disk |
| 13-receipt-index | `receipt-index` | regen RECEIPTS.md + receipts/INDEX.md |
| 13-receipt-index | `receipt-index-check` | restore committed bytes on drift; fails loudly |
| 13-receipt-index | `receipt-durability-gate` | read-only durability gate over receipt files |
| 14-sdk-matrix | `sdk-matrix` | SDK surface matrix court: pass-or-registered |
| 14-sdk-matrix | `sdk-matrix-md` | render SDK_MATRIX.md (fails on MISSING/UNREGISTERED-GAP) |
| 15-bench | `bench-machine` | print machine spec block every bench lane must embed |
| 15-bench | `bench-report` | aggregate bench/*.jsonl into BENCH_RESULTS.md |
| 18-shim-court | `shim-court <name>` | run one shim court (scripts/shim_court/<name>_court.sh) |
| 18-shim-court | `shim-courts` | run all shim courts, PASS/FAIL/SKIP summary |
| 19-wave-telemetry | `wave-report` | wave telemetry report; honest empty-state message |
| 20-sobelow | `sobelow` | static security scan over lib/ (non-blocking) |
| 21-enclave | `enclave-loop` | terraform enclave lane e1; emits e1-enclave-loop.jsonl; loud-skip exit 3 |
| 22-native | `test-native [fixture] [tier]` | terraform tier suite |
| 22-native | `apply [fixture] [tier]` | apply; tier=wire delegates to cleanroom ladder |
| 22-native | `destroy [tier]` | reverse-topological destroy through real ARM router |
| 22-native | `verify [fixture]` | verify against same live beam |
| 22-native | `audit-residue` | apply + destroy + per-table residue audit, fail-closed on non-empty |
| 22-native | `cleanroom` | terraform cleanroom ladder |
| 22-native | `trust-status` | machine-readable `{"status":"PASS\|FAIL\|UNREACHABLE"}` |
| 22-native | `doctor-json` | JSON doctor receipt variant (just aborts on duplicate names, hence separate recipe) |
| 22-native | `preflight` / `fix-start TEST` / `fix-end` / `spc-check` | lane preflight; fix-mode freeze of court witnesses around one failing test; SPC band check |
| 23-compliance | `test-compliance` / `test-compliance-wire` | compliance tier suites (offline + wire args passthrough) |
| 24-quiesce | `quiet-check` | ports free + no concurrent suites/courts; exit 1 loudly on violation |
| 24-quiesce | `quiesce` / `quiesce-warm` | quiesce the machine before `just court-x2` (warm variant pre-warms) |
| 25-leak-court | `leak-court` | `gates/test_isolation_leak_gate.py` static leak scan over `test/` |
| 25-leak-court | `leak-court-count` | advisory count only, never fails |
| 25-leak-court | `isolation-court` / `isolation-court-runtime` | start_supervised!/put_env-restore discipline; runtime twin diffs registered()/env per module |
| 26-rewitness | `kd-stale` | list KD rows whose witness chain is stale (witness mtime < newest shim mtime) |
| 26-rewitness | `rewitness KD` | re-run one row's witness; missing witness exits 3 typed |
| 27-scratch-soak | `wt-scratch SHA` | cross-SHA inspection via git archive (no worktree) |
| 27-scratch-soak | `corpus-soak N` | run the corpus N times, gate on flake rate; exit 1 on any failing round |
| 28-stress | `test-stress` | stress-tier suite |
| 28-test-budget | `test-budget-seed` / `test-budget` | export + fail-closed gate against `test_budgets.json` (seed is a reviewed diff) |
| 29-sleep | `sleep-gate` / `sleep-gate-court` | NO-SLEEP-DOCTRINE Law 3 gate + non-vacuity court (see `docs/NO_SLEEP_DOCTRINE.md`) |
| 30-burn | `burn` (+ `burn-soak`/`-chaos`/`-matrix`/`-ring`/`-boot`/`-clean`/`-ocel`/`-in-container-verify`/`-chaos-kill`) | full burn: host soak + container matrix; boot rows stop the line on ORPHAN_LISTENER/ZOMBIE_BEAM/UNHANDLED_EXIT |
| 30-burn | `overlap-court` (+ `-serial`/`-check`/`-compare`/`-report`) | scheduler-overlap anti-vacuity court — a pass from a vacuous scheduler is the failure |

## See Also

- `docs/JUST_REFERENCE.md` — per-recipe exit contracts and durations
- `justfile.d/` — module sources
