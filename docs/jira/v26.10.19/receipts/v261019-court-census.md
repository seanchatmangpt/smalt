# v26.10.19 Court-Standing Census (lane: cen)

Date: 2026-10-19. Read-mostly census lane, private build root
`MIX_BUILD_ROOT=_build-lane-cen`, no fixes applied, no git operations.
Honest reds are the deliverable.

**Headline finding: the shared `lib/` tree does not compile.**
`lib/smalt/messaging/event_grid.ex` fails at lines 237 and 247 — a local function
`dlq_enabled?/1` invoked inside a guard. mtime of the file is 2026-10-19 10:09:05,
i.e. an in-flight edit from another lane. Per the compile-freeze SLA the owning lane
must fix or revert within ~10 min; this census observed the frozen state twice,
~40 min apart. It blocks `mix test` and all of `invariant_gates.py`.

## Verdict table

| Stage | Verdict | Notes |
|---|---|---|
| `just doctor` | PASS (1 advisory) | dev CA not trusted by macOS keychain (known dev-env advisory) |
| `mix test` (residual tier, `_build-lane-cen`) | BUILD-BROKEN | `event_grid.ex` CompileError; 0 tests executed |
| `just naming-sweep` | PASS | 0 violations / 50 allowed |
| `scripts/non_duplication_gate.py` | PASS | 6 files clean |
| `scripts/portable_target_gate.py` | FAIL (exit 1) | 5,655 violation lines — all vendored `verification/ts/node_modules/wsl-utils/*`, not first-party code |
| `scripts/sleep_gate.py` | FAIL (exit 1) | 114 violations / 2,024 files; 103 are `verification/py/.venv` site-packages (venv not excluded); 11 first-party — NOT the expected 3 known sites (premise drift finding) |
| `scripts/invariant_gates.py` | FAIL 6/6 | every gate dies on the same `event_grid.ex` CompileError — compile-frozen, not product regressions |
| `scripts/sdk_coverage.py` | FAIL (exit 1) | 75 MISSING probe-cell findings (expected honest reds); kd-annotation cells: SIM-PASS=5 REGISTERED-DIVERGENCE=2 MISSING=0; capability cells: PASS=4 PASS-PARTIAL=3 |
| `just bench-check` | FAIL (exit 1) | bench receipt stale 37.22 h vs 24 h bound; refresh via `scripts/bench.py` |
| `scripts/receipt_index.py` | PASS-with-SUSPECT (exit 0) | 25 SUSPECT rows (TBD/skeleton receipts), expected; regenerated RECEIPTS.md/INDEX.md for v26.10.14–19 |

## Pasted output backing each verdict

### `just doctor`
```
=== SMALT DOCTOR DIAGNOSTIC COURT (v2) ===
[PASS] binaries (0.2ms): ok
[PASS] port-arm (0.1ms): ok
[PASS] port-data (0.0ms): ok
[PASS] port-amqp (0.0ms): ok
[PASS] gitignore-coverage (0.1ms): ok
[PASS] dev-key-perms (0.3ms): ok
[PASS] dev-certs (0.1ms): present (.smalt/tls/dev-cert.pem)
[ADVISORY] keychain-trust (42.9ms): dev CA not trusted by macOS System keychain (Go TLS via Apple Security.framework will reject the leaf): Cert Verify Result: CSSMERR_TP_NOT_TRUSTED
[PASS] tmp-dirs (0.1ms): ok
[PASS] mix-deps-freshness (1752.5ms): INFO 89 locked deps
[PASS] recent-receipts (6.8ms): INFO 1/2 receipt(s) stale >24h: bench-receipt.json (37.2h old)
[PASS] spc-bands (73.7ms): PASS verdict=PASS tier=0 seeded=False
[SUBSTRATE] booted=False ports={'5672': 'free', '5673': 'free', '8443': 'free', '9443': 'free', '9444': 'free'} receipts={'newest_receipt_age_hours': 9.3, 'stale': False, 'count': 2}
[PASS] Smalt doctor diagnostic court passed.
```

### `MIX_BUILD_ROOT=_build-lane-cen mix test` — BUILD-BROKEN
```
==> smalt
Compiling 145 files (.ex)
     error: cannot find or invoke local dlq_enabled?/1 inside a guard. Only macros can be invoked inside a guard and they must be defined before their invocation. Called as: dlq_enabled?(dlq)
 247 │         when dlq_enabled?(dlq) ->
     │              ^
     └─ lib/smalt/messaging/event_grid.ex:247:14: Smalt.Messaging.EventGrid.handle_info/2
     error: cannot find or invoke local dlq_enabled?/1 inside a guard ...
 237 │         when dlq_enabled?(dlq) and attempts >= dlq.max_delivery_attempts ->
     └─ lib/smalt/messaging/event_grid.ex:237:14: Smalt.Messaging.EventGrid.handle_info/2
== Compilation error in file lib/smalt/messaging/event_grid.ex ==
** (CompileError) lib/smalt/messaging/event_grid.ex: cannot compile module Smalt.Messaging.EventGrid (errors have been logged)
```
Retry ~40 min later (`mix compile --warnings-as-errors`): identical CompileError.
`event_grid.ex` mtime: `1792429745 Oct 19 10:09:05 2026`.

### `just naming-sweep`
```
[NAMING-SWEEP] PASS: 0 violations / 50 allowed
```

### `scripts/non_duplication_gate.py`
```
[PASS] non-duplication gate: 6 file(s) clean
```

### `scripts/portable_target_gate.py` — FAIL, exit 1
Full log: `/tmp/cen-ptg.log` (5,655 lines). Representative violations:
```
verification/ts/node_modules/wsl-utils/index.d.ts:151: HARD violation (/Users/ absolute path): @returns The WSL path (e.g., `/mnt/c/Users/file.txt`) or the original path if conversion fails.
verification/ts/node_modules/wsl-utils/index.d.ts:155: disallowed import: wsl-utils
verification/ts/node_modules/wsl-utils/index.js:5: disallowed import: is-wsl
verification/ts/node_modules/wsl-utils/index.js:6: disallowed import: powershell-utils
verification/ts/node_modules/wsl-utils/readme.md:99: HARD violation (absolute home path): const windowsPath = await convertWslPathToWindows('/home/user/file.html');
```
All sampled lines are vendored `node_modules` content under `verification/ts/` —
a scanner-scope issue (vendored deps not excluded), not first-party violations.

### `scripts/sleep_gate.py` — FAIL, exit 1
`[SLEEP-GATE] 114 violation(s) across 2024 files — REFUSED`. Full log `/tmp/cen-sg.log`.
Composition of the 114:
- 103 in `verification/py/.venv/.../site-packages` (pip/_vendor/rich, urllib3,
  msal_extensions) — the venv is not excluded from the gate's sweep.
- 11 first-party (verified by `grep -v .venv`):
  - `test/internal/poll_helper.exs:74` — `Process.sleep(min(poll_ms, remaining))`
  - `test/internal/vm_zero_growth_test.exs:100` — `holder = fn -> receive do after 86_400_000 -> :ok end end`
  - `verification/py/conftest.py:132,172,196,214` — `time.sleep(0.2/0.5/0.25/0.05)`
  - `verification/py/test_wf3_messaging.py:272` — `await asyncio.sleep(0.2)`
  - `verification/py/harness/poll.py:22` — `time.sleep(poll_s)`
  - `verification/ts/harness/poll.ts:24,37` and `verification/ts/harness/substrate.ts:151`

The dispatch brief expected "the 3 known unclassified test/internal sites". Observed
first-party sites = 11 (2 in `test/internal/` + 9 in `verification/`). The pinned
premise is stale: the `verification/` trees are new this milestone and have never been
classified (no `# SLEEP-CLASS:` annotations, not in the audited-poll allowlist). Per the
test-premises-rot law this is a register finding, not a gate bug.

### `scripts/invariant_gates.py` — FAIL 6/6
Full log `/tmp/cen-ig.log`. Every gate fails on the identical compile error:
```
** (CompileError) lib/smalt/messaging/event_grid.ex: cannot compile module Smalt.Messaging.EventGrid (errors have been logged)
```
```
================ INVARIANT-GATES VERDICT TABLE ================
  appconfig-etag-cas   FAIL
  blob-worm            FAIL
  cosmos-etag-cas      FAIL
  ledger-chain         FAIL
  lock-clamp           FAIL
  queue-capacity       FAIL
================================================================
[INVARIANT-GATES] FAIL: 6/6 gate(s) failed.
```
Verdicts are compile-frozen artifacts, not product regressions. One gate
(queue-capacity) wrote a FAIL receipt to `tmp/invariant-gates/queue-capacity-receipt.json`.

### `scripts/sdk_coverage.py` — FAIL, exit 1 (honest MISSING)
Full log `/tmp/cen-sc.log`. 75 `FINDING: <surface>/{ts,py}: MISSING probe cell` rows
(verified `grep -c '^FINDING'` = 75). Representative:
```
FINDING: eventgrid/ts: MISSING probe cell
FINDING: eventhubs/py: MISSING probe cell
FINDING: sentinel/{ts,py}, resource-graph/{ts,py}, purview-atlas/{ts,py}, ledger/{ts,py}, appconfig/{ts,py}: MISSING probe cell
kd-annotation cells: SIM-PASS=5 REGISTERED-DIVERGENCE=2 MISSING=0
capability cells: PASS=4 PASS-PARTIAL=3 REGISTERED-DIVERGENCE=0 UNREGISTERED-GAP=0 MISSING=0
```
These are the expected honest MISSING findings named in the dispatch brief. Note the
census counters themselves report MISSING=0 for kd-annotation cells — the 75 are
capability probe cells awaiting the SDK-matrix expansion.

### `just bench-check` — FAIL, exit 1
```
[COURT] Performance regression gate...
  FAIL detail [receipt]: stale receipt — rerun scripts/bench.py
== Bench Gate ==
  receipt                       37.22 h  (<= 24.0) -> FAIL
Gate: FAIL (0/1 CTQs pass)
```
Root cause is receipt staleness only; no perf numbers were measured or compared.

### `scripts/receipt_index.py` — exit 0, 25 SUSPECT rows
```
  SUSPECT: kd111-arm-lro-narrow-tbd.md (standing UNKNOWN)
  SUSPECT: kd112-arm-policy-initiatives-tbd.md (standing UNKNOWN)
  SUSPECT: kd113-arm-rbac-storage-only-tbd.md (standing UNKNOWN)
  SUSPECT: v261019-09-py-external-suite.md (standing UNKNOWN)
  SUSPECT: v261019-14-boot-library.md (standing UNKNOWN)
```
(Expected per brief: SUSPECT skeletons are fine.) Side effect as designed: it
regenerated `RECEIPTS.md` + `receipts/INDEX.md` for v26.10.14/16/17/18/19.

## Standing

Census standing: **SUSPECT**. Blocker chain: `event_grid.ex` (owning lane, in-flight
edit since 10:09:05) freezes compile → `mix test` and `invariant_gates.py` 6/6 red.
Everything else is independently legible: naming/non-duplication/doctor green;
portable-target and sleep-gate red on scanner-scope issues (vendored node_modules,
unclassified verification/ trees, unexcluded venv) plus one genuine premise-drift
finding (sleep-gate expected-sites count: 3 pinned vs 11 observed); bench-check red on
receipt staleness; sdk-coverage red on 75 expected MISSING cells.

Full raw logs retained: `/tmp/cen-ptg.log`, `/tmp/cen-sg.log`, `/tmp/cen-ig.log`,
`/tmp/cen-sc.log`.

## Final census 2026-10-20 (pre-wrap, HEAD 28ceff9)

Full acceptance machine at final HEAD `28ceff9b17173494ded6074a5212acc8183dff7f`.
Verdict per gate (rc | one-line evidence):

| Gate | rc | Evidence |
|---|---|---|
| acceptance_gates.py (5-gate) | 1 (FAIL) | G3/G4/G5 PASS, G2 PENDING (typed SKIP, suites not green yet); **G1 FAIL** — 13 UNEXPECTED test paths (cosmos_sql_raise, kql, sentinel_multitable, arm_consumer_group_bridge, certificates_kd104_witness, deletedkeys_purge_route, event_grid_webhook, policy_enforcement_mode_witness, policy_remediation_witness, eh_arm, eh_geo_dr, event_hubs_consumer_groups, sb_topic_fanout) |
| envelope/automation_gate.py | 1 (REFUSED) | 1 violation / 166 files: `scripts/gen_error_codes.py:592 DEPRECATED-TEST-PATH` — reference to retired test tree `test/compliance` |
| envelope/container_gate.py | 0 (PASS) | static=0 runtime=0; hermetic Dockerfile green; 2 reference-only notes (no USER/HEALTHCHECK in reference image, non-gating) |
| envelope/iac_gate.py | 0 (PASS) | scripts/tf_fixtures + tf_fixtures_per_resource clean |
| envelope/orchestration_gate.py | 0 (PASS) | 9 manifests under k8s/ + docker/compose*, 0 violations |
| scripts/leak_detector.sh | 1 (FAIL) | 1 orphan: epmd pid 8111 (zero registered nodes); canonical ports 9443/9444/8443/5672/5673 held by healthy substrate beam 1403; remediate `scripts/port_sweep.sh -y` |
| scripts/non_duplication_gate.py | 0 (PASS) | 9 file(s) clean |
| scripts/portable_target_gate.py | 0 (PASS) | 26 file(s) clean |
| sleep gate (just sleep-gate) | 1 (REFUSED) | 6 violations / 216 files, all unclassified ts/js sleep primitives in verification/ts: census.test.cjs:104,135,483; sb-extra.probe.cjs:98,144,192 (need `# SLEEP-CLASS:`) |
| just doctor | 0 (PASS) | 12 PASS + substrate booted, all 5 ports listening, 2 advisories only (dev CA untrusted in System keychain; 1/2 receipts stale >24h — test-budget-gate-receipt.json 28.2h) |
| scripts/naming_sweep.sh | 0 (PASS) | 0 violations / 49 allowed |
| gen_error_codes.py --check | 1 (FAIL) | `docs/ERROR_CODES.md is stale` — line-number drift in lib/smalt/arm_gateway/router.ex citations (router grew ~53-253 lines since last regen); regen required, no semantic code changes in diff |
| scripts/sdk_coverage.py | 0 (OK) | window v26.10.19: cells PASS=22, MISSING=0, UNREGISTERED-GAP=0, REGISTERED-DIVERGENCE=2 (blob/ts KD-92, cosmos/ts KD-93 — both OPEN, receipted); wf-receipt FAILs surfaced honestly: wf2-ts cosmos=FAIL, wf3-ts servicebus=FAIL, wf4-ts keyvault=FAIL; servicebus census CRC OK (11/11/11) |

**Tally: 8 green / 4 red** (acceptance G1, automation-gate, leak-detector,
sleep-gate) plus gen_error_codes drift check = 5 red total across 13 checks.

Red-cluster reading: 3 of the 4 gate reds are receipt-of-record hygiene
(acceptance G1 unexpected test paths are the new capability-wave-3 suites not yet
registered into the expected set; automation-gate's single violation is a
DEPRECATED-TEST-PATH string inside the error-code generator itself;
gen_error_codes --check is line-number drift from the same router growth), and the
4th/5th (leak-detector epmd orphan; 6 unclassified sleeps in verification/ts) are
environment/scanner-scope items, none a data-plane or wire regression. G2 remains
typed-PENDING (mix suite green-ness not witnessed in this census — `mix test` was
not run in this lane's scope). No code was edited; this lane appended only to this
receipt.

Standing: **PARTIAL_ALIVE** — machine runs end-to-end at 28ceff9; pre-wrap reds
are honest and itemized above for the wrap sequence to consume.

## Wave-5 pre-census (2026-10-20, lane: bench-visual, HEAD bab1949)

Read-mostly census at current HEAD. Honest reds are the deliverable.

| Gate | rc | Evidence |
|---|---|---|
| `scripts/acceptance_gates.py` (5-gate) | FAIL (script rc 1; harness echo 0) | G1 FAIL: 10 UNEXPECTED test paths (cosmos_pkranges, kql, purview_glossary, sentinel_multitable, arm_dcr, sb_arm_rules, eh_arm, eh_geo_dr, eh_consumer_groups…); G2/G3 PENDING/FAIL; G4 PASS; G5 PASS |
| `scripts/envelope/automation_gate.py` | FAIL (1 violation) | `scripts/gen_error_codes.py:592 DEPRECATED-TEST-PATH` — reference to retired `test/compliance` tree (owning surface: scripts/gen_error_codes.py) |
| `scripts/envelope/container_gate.py` | PASS | static=0 runtime=0; 2 reference notes on docker/Dockerfile (no USER/HEALTHCHECK, non-gating); runtime mode loud-skip (no hermetic image) |
| `scripts/envelope/iac_gate.py` | PASS | scripts/tf_fixtures + tf_fixtures_per_resource clean |
| `scripts/envelope/orchestration_gate.py` | PASS | 9 manifests scanned under k8s/ + docker/compose*, 0 violations |
| `scripts/leak_detector.sh` | FAIL | 1 orphan detected (beam/epmd=1, node=0): beam.smp pid 67268 still holds 9443/9444/8443/5672/5673 post-sweep — same pid doctor reports as the healthy substrate; remediation pointer scripts/port_sweep.sh -y (owning surface: substrate lifecycle / scripts/leak_detector.sh orphan heuristic) |
| `scripts/non_duplication_gate.py` | PASS | 9 files clean |
| `scripts/portable_target_gate.py` | PASS | 26 files clean |
| `scripts/sleep_gate.py` | PASS | 220 files, 0 unclassified sleep primitives |
| `python3 scripts/doctor.py` | PASS (1 advisory) | substrate booted pid 67268 all 5 ports listening; advisory keychain-untrusted (dev CA, known dev-env) |
| `scripts/naming_sweep.sh` | PASS | 0 violations / 49 allowed |
| `scripts/gen_error_codes.py --check` | FAIL | `docs/ERROR_CODES.md is stale` — 40-line diff (arm-gateway 404/409 rows: RuleNotFound, SubscriptionNotFound, TableNotFound, SecretVersionNotFound from router.ex); owning surface: docs/ERROR_CODES.md regeneration |
| `scripts/sdk_coverage.py` | FAIL (1 finding) | UNREGISTERED-GAP cap-cell `appconfig-snapshots` (standing PREP, receipt v261019-capability-wave3.md); other cells: PASS / PASS-PARTIAL / REGISTERED-DIVERGENCE (kd117, kd118) as expected |

Reds summary (3): acceptance G1 unexpected-path drift (owning surface: caps-w4 test landing vs G1 manifest),
ERROR_CODES.md staleness (owning surface: docs regeneration after wave-4 router additions),
sdk_coverage UNREGISTERED-GAP appconfig-snapshots (owning surface: KD register row missing for wave-3 cell).
Leak-detector FAIL is the live healthy substrate flagged as orphan (pid 67268, substrate booted=True) — classifier conflict, not a real leak.
