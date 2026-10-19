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
