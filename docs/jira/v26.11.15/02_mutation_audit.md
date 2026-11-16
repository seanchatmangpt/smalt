# Smalt Mutation & Anti-Vacuity Audit (v26.11.15)

**Auditor**: Agent 16 (Smalt Mutation & Anti-Vacuity Auditor)  
**Date**: 2026-11-16  
**Target Repository**: `/Users/sac/smalt`  
**Artifact Path**: `/Users/sac/smalt/docs/jira/v26.11.15/02_mutation_audit.md`  
**Audit Objective**: Rigorous evaluation of all in-repo mutation scripts, test mutators, boundary falsifiers, anti-vacuity defenses, mutant survival rates, and unmutated/vacuous logic paths.

---

## 1. Executive Summary

A comprehensive, live audit was conducted across all mutation testing harnesses, anti-vacuity mechanisms, and adversarial courts in `/Users/sac/smalt`. The repository contains sophisticated anti-vacuity infrastructure, notably the `gates/common.py` mutation-verdict harness, the 50-court `scripts/shim_court/` framework, the sovereign `must_not_migrate_gate.py` self-check suite, and SPARQL invariant non-vacuity tests.

However, the audit identified **multiple critical failures, broken mutation paths, vacuous mutant assertions, and extensive test decay**:
1. **Vacuous Mutant Kill in `posh_mutation_court.py` (M3)**: Mutant M3 attempts to test disconnected OCPQ graph traversals by executing `python -m pm4pytest.cli check-ocpq`. However, `check-ocpq` is **not a valid command** in `pm4pytest.cli`. The CLI exits with code 2 (`Error: No such command 'check-ocpq'`). Because `posh_mutation_court.py` merely tests `res.returncode == 0`, it misinterprets a CLI syntax error as a successful mutant kill.
2. **Missing Dependency Crash in `enterprise_compliance_court.sh` & `posh_mutation_court.py`**: Both scripts hardcode `PM4PYTEST_ROOT="/Users/sac/ggen-marketplace/packages/pm4pytest/src"`, which does not exist on disk (the real package is vendored at `/Users/sac/fnox/vendor/pm4pytest/src`). As a result, Stage 6 crashes with `ModuleNotFoundError: No module named 'pm4pytest'`, blocking Stage 7 mutation testing entirely.
3. **Broken Harness in `scripts/live_gate_court.sh`**: The mutation regex in `live_gate_court.sh` failed to land on `popcorn_demo/scripts/browser_smoke.mjs` because the subject script added an SCVD gate (`finalExit = exitCode === 3 ? 3 : Math.max(exitCode, scvdGate.verdict)`), causing an unhandled `AssertionError: shim edit did not land`.
4. **Runtime Crash in `scripts/shim_court/kafka_vs_aoq_court.sh`**: The unshimmed baseline check failed with `(UndefinedFunctionError) function Smalt.Planes.resolve/0 is undefined` because it runs with `--no-compile` on an uncompiled private build root (`_build-lane59`).
5. **Environment Missing in `scripts/shim_court/amqp_framing_court.sh`**: Blocked with exit code 2 because `/Users/sac/smalt/test/sdk-python/.venv-sb/bin/python` does not exist.
6. **13+ Shim Courts Permanently Skipped / Degraded**: 13 shim courts targeting AMQP and storage invariants skip loudly because their test suites (e.g., `test/amqp/connection_test.exs`, `test/amqp/event_hubs_test.exs`, `test/amqp/lock_manager_test.exs`, `test/amqp/queue_store_test.exs`, `test/corpus_test.exs`) were removed in the `64f6099` compliance-corpus reset and never restored.
7. **`test-isolation-leak` Invariant Gate Failure**: While positive gates pass (`blob-worm`, `cosmos-etag-cas`, `ledger-chain`, `lock-clamp`, `queue-capacity`, `appconfig-etag-cas`), `test-isolation-leak` fails because 75 test files across `test/` leak 108 un-isolated state mutations (`Application.put_env`, ETS tables) without cleanup.
8. **Scalability Bottleneck in Shim Courts**: 22 shim courts hardcode separate `MIX_BUILD_ROOT` directories, forcing redundant 4-6 minute cold compilations of 733 Elixir files and 91 dependencies, rendering `just shim-courts` impractical to run sequentially without timeouts.

---

## 2. In-Repo Mutation & Anti-Vacuity Inventory

| Harness / Tool | Primary Locus | Method / Technique | Live Execution Result |
|---|---|---|---|
| **POSH Admission Mutation Court** | `scripts/posh_mutation_court.py` | 8-stage court: baseline, receipt tamper, IMDS trap, singleflight, Chicago falsifiers, compliance court, 3 mutants (SLA, FSM, OCPQ), KeyVault state | **FAILED (Stage 6 crash + Stage 7 M3 vacuous)** |
| **Enterprise Compliance Court** | `scripts/enterprise_compliance_court.sh` | 5-stage IEEE OCEL 2.0 & pm4pytest Petri net / SLA / OCPQ invariant court | **FAILED (`ModuleNotFoundError: pm4pytest`)** |
| **Sovereign Must-Not-Migrate Gate** | `scripts/must_not_migrate_gate.py` | Injects F1, F2, F2b, T1a, T1b, T3, T5 violations on `/tmp` scratch copy; proves clean pass + restored clean | **PASS (All 6 mutations refused)** |
| **POSH SPARQL Invariant Court** | `justfile.d/58-posh.just` (`posh-invariant-court`) | Injects orphan route individual into temporary TTL copy; asserts exit 1 + exact query name + byte-exact restore | **PASS (Gate flipped, restored byte-exact)** |
| **POSH SPARQL Invariant Gate** | `scripts/posh_invariant_gate.py` | Fails closed if 0 queries found (anti-vacuity); checks merged T-box/A-box | **PASS (2 queries, 0 violations)** |
| **Fail-Closed Invariant Gates** | `scripts/invariant_gates.py` (`gates/*_gate.py`) | Positive test against live substrate + negative mutated transcripts (snapshot under hold, race double-winner, etc.) | **FAILED (6/7 PASS, `test-isolation-leak` FAIL)** |
| **GraphLaw Mutation Court & Probes** | `scripts/mutation_court.py` | In-place gate bypass on `validator.ex` + 6 source-mutant probes across auth, blob, cosmos, lro | **SELF-CHECK PASS (Probes target burn corpus)** |
| **Receipt Provenance Validator** | `scripts/validate_receipt.py --selftest` | 3 non-vacuity legs (A: bad shape, B: missing source, C: lawful receipt) | **PASS (All 3 legs fired)** |
| **Port Registry Check Falsifiers** | `scripts/port_registry_check.py --falsify` | 19 corpus falsifier cases exercising overlapping, out-of-bounds, frozen blocks | **PASS (19 cases passed)** |
| **Live Gate Browser Smoke Court** | `scripts/live_gate_court.sh` | Injects unconditional `process.exit(0)` into copy of `popcorn_demo/scripts/browser_smoke.mjs` | **FAILED (`AssertionError: shim edit did not land`)** |
| **50 Reusable Shim Courts** | `scripts/shim_court/*_court.sh` | SHA-baseline -> BEFORE -> SHIM (in-place) -> AFTER -> RESTORE byte-exact | **MIXED: 11 PASS, 15 SKIP, 2 FAIL/BLOCKED, 22 TIMEOUT** |

---

## 3. Detailed Audit Findings

### Finding 1: Vacuous Mutant Kill in `posh_mutation_court.py` (Mutant M3)

- **Affected File**: `/Users/sac/smalt/scripts/posh_mutation_court.py` (lines 117–130)
- **Severity**: Critical (Anti-Vacuity Integrity Breach)
- **Issue Description**:
  In `posh_mutation_court.py`, Stage 7 defines Mutant M3 to test that disconnected OCPQ traversals over unlinked object types (`Tenant,NonExistentType,Workspace`) are rejected.
  However, the script executes:
  ```python
  cmd_ocpq_mutant = [
      python313, "-m", "pm4pytest.cli", "check-ocpq",
      "--log", "/tmp/enterprise_compliance_audit.ocel.json",
      "--traverse", "Tenant,NonExistentType,Workspace",
      "--format", "tap"
  ]
  ```
  In `pm4pytest.cli`, the subcommand for graph traversal and invariant queries is `query`, **not** `check-ocpq`. There is no `check-ocpq` command.
  When executed, `pm4pytest.cli` fails with exit code 2:
  ```
  Usage: python -m pm4pytest.cli [OPTIONS] COMMAND [ARGS]...
  Try 'python -m pm4pytest.cli --help' for help.
  Error: No such command 'check-ocpq'. Did you mean 'check-sla'?
  ```
  The assertion in `posh_mutation_court.py` is:
  ```python
  if res_ocpq.returncode == 0 and "not ok" not in res_ocpq.stdout:
      print("[MUTATION-COURT-FAIL] Disconnected traversal mutation was VACUOUSLY ACCEPTED! Expected refusal.")
      return False
  print("[MUTATION-COURT] Mutant M3 (Disconnected OCPQ traversal): KILLED (Correctly Refused)")
  ```
  Because `res_ocpq.returncode == 2`, the condition `res_ocpq.returncode == 0` is false, and the test reports that the mutant was "KILLED (Correctly Refused)".
  A Typer CLI syntax error is falsely counted as a killed mutant.
- **Live Command Executed**:
  ```sh
  PYTHONPATH="/Users/sac/fnox/vendor/pm4pytest/src" \
    /opt/homebrew/opt/python@3.13/bin/python3.13 -m pm4pytest.cli check-ocpq \
    --log "/tmp/enterprise_compliance_audit.ocel.json" \
    --traverse "Tenant,NonExistentType,Workspace" --format tap
  ```
- **Command Output**:
  ```
  Usage: python -m pm4pytest.cli [OPTIONS] COMMAND [ARGS]...
  Try 'python -m pm4pytest.cli --help' for help.
  ╭─ Error ──────────────────────────────────────────────────────────────────────╮
  │ No such command 'check-ocpq'. Did you mean 'check-sla'?                      │
  ╰──────────────────────────────────────────────────────────────────────────────╯
  ```
  (Exit code: 2)

---

### Finding 2: Missing Path Dependency in `enterprise_compliance_court.sh` & `posh_mutation_court.py`

- **Affected Files**:
  - `/Users/sac/smalt/scripts/enterprise_compliance_court.sh` (line 18)
  - `/Users/sac/smalt/scripts/posh_mutation_court.py` (line 86)
- **Severity**: High (Broken Gate Execution)
- **Issue Description**:
  Both scripts specify:
  ```sh
  PM4PYTEST_ROOT="/Users/sac/ggen-marketplace/packages/pm4pytest/src"
  ```
  and
  ```python
  pm4py_root = Path("/Users/sac/ggen-marketplace/packages/pm4pytest/src")
  ```
  This path does not exist. The actual location of `pm4pytest` in the ecosystem is `/Users/sac/fnox/vendor/pm4pytest/src`.
  Consequently, Stage 6 of `posh_mutation_court.py` and Stage 3 of `enterprise_compliance_court.sh` immediately crash with `ModuleNotFoundError: No module named 'pm4pytest'`. Because Stage 6 crashes, Stage 7 (the mutation tests) never runs in standard CI or local court execution.
- **Live Command Executed**:
  ```sh
  python3 /Users/sac/smalt/scripts/posh_mutation_court.py
  ```
- **Command Output**:
  ```
  === POSH ADMISSION MUTATION COURT ===
  [MUTATION-COURT] Stage 1: Running baseline positive checks...
  [MUTATION-COURT] Baseline checks: PASS
  [MUTATION-COURT] Stage 2: Proving receipt tamper rejection (non-vacuity)...
  [MUTATION-COURT] Receipt tamper rejection: NON-VACUOUS (tamper correctly rejected)
  [MUTATION-COURT] Stage 3: Proving IMDS and unspecified address trapping (non-vacuity)...
  [MUTATION-COURT] IMDS and unspecified socket trap: NON-VACUOUS (forbidden egress blocked)
  [MUTATION-COURT] Stage 4: Proving singleflight context cancellation isolation...
  [MUTATION-COURT] Singleflight isolation: NON-VACUOUS (31 callers survived goroutine 0 cancellation)
  [MUTATION-COURT] Stage 5: Proving Chicago adversarial falsifiers & turnstile refusal...
  [MUTATION-COURT] Chicago adversarial falsifiers: NON-VACUOUS (tampered & omitted tokens hard refused)
  [MUTATION-COURT] Stage 6: Proving Enterprise 7-gap OCEL 2.0 & pm4pytest compliance court...
  [MUTATION-COURT-FAIL] Enterprise compliance court failed:
  /opt/homebrew/opt/python@3.13/bin/python3.13: Error while finding module specification for 'pm4pytest.cli' (ModuleNotFoundError: No module named 'pm4pytest')

  ========================================================================
    ENTERPRISE MULTI-TENANT COMPLIANCE COURT (IEEE OCEL 2.0 & PM4PYTEST)
  ========================================================================
  [STAGE 1/5] Running Chicago Loopback Test to Emit Compliant OCEL v2 Log...
  === RUN   TestChicago_EnterpriseCompliance_OCELv2_Emission
      enterprise_ocel_test.go:281: [ENTERPRISE-OCEL] Wrote fully compliant log to /tmp/enterprise_compliance_audit.ocel.json (len events: 9, len objects: 6)
  --- PASS: TestChicago_EnterpriseCompliance_OCELv2_Emission (0.00s)
  PASS
  ok  	smalt.dev/posh/tests/chicago	6.760s
  [STAGE 2/5] Verifying Strict IEEE OCEL 2.0 Schema & Referential Integrity...
  [OCEL2-VAL] PASS /tmp/enterprise_compliance_audit.ocel.json: 9 events, 6 objects, referential integrity OK
  [STAGE 3/5] Evaluating Petri Net FSM Conformance (Fitness = 1.0 required)...
  ```
  (Exit code: 1)

---

### Finding 3: Mutator Regex Drift in `scripts/live_gate_court.sh`

- **Affected File**: `/Users/sac/smalt/scripts/live_gate_court.sh` (lines 38–43)
- **Target File**: `/Users/sac/smalt/popcorn_demo/scripts/browser_smoke.mjs`
- **Severity**: High (Broken Non-Vacuity Court)
- **Issue Description**:
  `scripts/live_gate_court.sh` verifies that the browser smoke test gate is non-vacuous by attempting to inject an unconditional `process.exit(0)` into a scratch copy of `browser_smoke.mjs`.
  The Python mutator uses the regex:
  ```python
  src = re.sub(
      r"const exitCode = \(\(\) => \{.*?\}\)\(\);\nprocess\.exit\(exitCode\);",
      "// SHIM-COURT: mutated exit logic — always zero\nprocess.exit(0);",
      src, flags=re.S)
  assert "SHIM-COURT" in src, "shim edit did not land"
  ```
  However, `browser_smoke.mjs` was updated to add rolling SCVD gate verification, changing the exit sequence to:
  ```javascript
  const exitCode = (() => { ... })();
  ...
  const finalExit = exitCode === 3 ? 3 : Math.max(exitCode, scvdGate.verdict);
  process.exit(finalExit);
  ```
  Because `process.exit(exitCode)` no longer directly follows the IIFE, the regex match fails and the mutator script aborts with `AssertionError: shim edit did not land`.
- **Live Command Executed**:
  ```sh
  bash /Users/sac/smalt/scripts/live_gate_court.sh
  ```
- **Command Output**:
  ```
  BASELINE: three exit arms present in browser_smoke.mjs
  BEFORE: sha256 af2722b751a0e4c4377ab28dade29c71550cb38d28e5a190be01d0b429546b30
  Traceback (most recent call last):
    File "<stdin>", line 10, in <module>
  AssertionError: shim edit did not land
  ```
  (Exit code: 1)

---

### Finding 4: Unhandled Module Resolution Failure in `scripts/shim_court/kafka_vs_aoq_court.sh`

- **Affected File**: `/Users/sac/smalt/scripts/shim_court/kafka_vs_aoq_court.sh` (lines 33–34)
- **Severity**: Medium (Failing Shim Court)
- **Issue Description**:
  The court runs the allocation probe using:
  ```bash
  L59_MODE=alloc MIX_ENV=test MIX_BUILD_ROOT=_build-lane59 \
    mix run --no-start --no-compile tmp/l59_runner.exs >"$LOG" 2>&1
  ```
  Because `_build-lane59` has never compiled `Smalt.Planes` and the command passes `--no-compile`, `Smalt.Planes.resolve/0` cannot be resolved at runtime. The baseline BEFORE check crashes with `UndefinedFunctionError` and exits with code 1.
- **Live Command Executed**:
  ```sh
  cd /Users/sac/smalt && bash scripts/shim_court/kafka_vs_aoq_court.sh
  ```
- **Command Output**:
  ```
  [kafka-vs-aoq] BASELINE 4da85ae1390f62a05ee9cd40bfee64fbd88dbc21a9813735858c357d76bb791b
  [kafka-vs-aoq] BEFORE (alloc fence must hold)
  bench/kafka_vs_aoq_court.erl:76:1: Warning: function kaf_target/0 is unused
  bench/kafka_vs_aoq_court.erl:83:1: Warning: function kaf_ff_target/0 is unused
  bench/kafka_vs_aoq_court.erl:90:1: Warning: function aoq_target/0 is unused
  BLOCKED(before): alloc probe failed unshimmed
  ** (UndefinedFunctionError) function Smalt.Planes.resolve/0 is undefined (module Smalt.Planes is not available)
      Smalt.Planes.resolve()
      (stdlib 8.1.1) erl_eval.erl:1048: :erl_eval.do_apply/7
      (stdlib 8.1.1) erl_eval.erl:792: :erl_eval.expr/6
      (stdlib 8.1.1) erl_eval.erl:276: :erl_eval.exprs/6
  ```
  (Exit code: 1)

---

### Finding 5: Missing Test Suites & Degraded Subjects Across Shim Courts

- **Affected Directory**: `/Users/sac/smalt/scripts/shim_court/`
- **Severity**: High (Extensive Court Invalidation / Dead Gates)
- **Issue Description**:
  During the `64f6099` compliance-corpus reset, several test directories (notably `test/amqp/` and `test/corpus_test.exs`) were removed. Numerous shim courts continue to reference these deleted files or subjects whose code has drifted, resulting in permanent `[SKIP]` verdicts:
  1. `disposition_token_court.sh`:
     - Subject `lib/smalt/messaging/amqp/connection.ex` no longer contains `lock_token: dlv.lock_token` settle threading.
     - Test file `test/amqp/connection_test.exs` is deleted.
     - Status: `[SKIP] subject degraded: connection.ex lacks lock_token: dlv.lock_token`
  2. `eh_batch_court.sh`:
     - Test file `test/amqp/event_hubs_test.exs` is deleted.
     - Status: `[SKIP] test file removed (64f6099 reset): test/amqp/event_hubs_test.exs`
  3. `orphan_token_court.sh`:
     - Test file `test/amqp/lock_manager_test.exs` is deleted.
     - Status: `[SKIP] test file removed (64f6099 reset): test/amqp/lock_manager_test.exs`
  4. `renew_mirror_court.sh`:
     - Test file `test/amqp/queue_store_test.exs` is deleted.
     - Status: `[SKIP] test file removed (64f6099 reset): test/amqp/queue_store_test.exs`
  5. `settle_cas_court.sh`:
     - Test file `test/amqp/queue_store_test.exs` is deleted.
     - Status: `[SKIP] test file removed (64f6099 reset): test/amqp/queue_store_test.exs`
  6. `corpus_fence_court.sh`:
     - Test file `test/corpus_test.exs` is deleted.
     - Status: `[SKIP] leg-retired: test/corpus_test.exs deleted at 64f6099 (compliance-corpus reset)`
  7. `tombstone_grace_court.sh`:
     - Test file `test/amqp/sweeper_test.exs` is deleted.
     - Status: `[SKIP] witness missing: test/amqp/sweeper_test.exs`
  8. `blob_worm_arms_court.sh`:
     - Test file `test/data_plane/blob_hardening_test.exs` is deleted.
     - Status: `[SKIP] test file missing: test/data_plane/blob_hardening_test.exs`
  9. `dets_growth_court.sh`:
     - Test file `test/store_dets_growth_test.exs` is deleted.
     - Status: `[SKIP] witness missing: test/store_dets_growth_test.exs`
  10. `ets_cleanup_court.sh`:
      - Test file `test/mcp_wire_test.exs` is deleted.
      - Status: `[SKIP] subject missing: test/mcp_wire_test.exs`
  11. `strata_cleanup_court.sh`:
      - Test file `test/strata_compat_test.exs` is deleted.
      - Status: `[SKIP] subject missing: test/strata_compat_test.exs`
  12. `eh_mgmt_court.sh`:
      - Probe `test/fixtures/eh_probe.js` is missing.
      - Status: `[SKIP] witness probe not found`
  13. `amqp_framing_court.sh`:
      - Python environment `test/sdk-python/.venv-sb/bin/python` is missing.
      - Status: `FAIL (exit 2) BLOCKED: pyamqp venv missing`
- **Live Verification**:
  ```sh
  ls -la /Users/sac/smalt/test/corpus_test.exs /Users/sac/smalt/test/amqp/
  # Output: ls: /Users/sac/smalt/test/amqp/: No such file or directory
  #         ls: /Users/sac/smalt/test/corpus_test.exs: No such file or directory
  ```

---

### Finding 6: Live Invariant Gate Failure in `gates/test_isolation_leak_gate.py`

- **Affected File**: `/Users/sac/smalt/gates/test_isolation_leak_gate.py`
- **Runner**: `/Users/sac/smalt/scripts/invariant_gates.py`
- **Severity**: High (State Pollution & Test Flakiness)
- **Issue Description**:
  `scripts/invariant_gates.py` runs the seven fail-closed invariant gates. Six gates (`appconfig-etag-cas`, `blob-worm`, `cosmos-etag-cas`, `ledger-chain`, `lock-clamp`, and `queue-capacity`) executed live and passed all positive tests and negative mutated transcript refusals (e.g., `snapshot-under-hold-accepted`, `overfill-accepted`, `two-winners`, etc.).
  However, the gate `test-isolation-leak` failed with exit code 1.
  The gate scans 397 test files and detected **108 uncovered state mutations across 75 test files**. Tests modify `Application.put_env(:smalt, ...)` or global ETS/pterm state without capturing previous values or restoring state in `on_exit` or `after` callbacks.
  This defect actively breaks test isolation when tests run concurrently or in random order.
- **Live Command Executed**:
  ```sh
  cd /Users/sac/smalt && python3 scripts/invariant_gates.py
  ```
- **Command Output (excerpt)**:
  ```
  === [INVARIANT-GATE] test-isolation-leak ===
  == test-isolation-leak court ==
  scanned 397 .exs files under test/ (0 allowlisted)

  -- positive: KNOWN-clean discipline fixtures --
  PASS fixture:clean-intact-save-plus-on_exit (expected PASS, scanner said PASS)
  PASS fixture:put_restored-site-covered (expected PASS, scanner said PASS)
  PASS fixture:put_restored-does-not-launder-raw-put_env (expected REFUSE, scanner said REFUSE)
  PASS fixture:on_exit-stripped (expected REFUSE, scanner said REFUSE)
  PASS fixture:literal-restore-no-save (expected REFUSE, scanner said REFUSE)

  -- OFFENDERS (75 files, 108 mutations uncovered) --
    test/config_alias_law_test.exs:124 env mutation `smalt.:blob_account_key` (no save of prev value)
    test/issuer_config_test.exs:26 env mutation `smalt.:issuer_host` (no save of prev value)
    test/json_compat_test.exs:84 env mutation `smalt.:json_engine` (no save of prev value)
    test/smalt_canonical_router_court_test.exs:32 env mutation `smalt.:ash_gateway` (no save of prev value)
    ... [71 additional files] ...

  verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=75 fixtures_refused=True receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json
  [INVARIANT-GATES] [FAIL] test-isolation-leak (exit 1)

  ================ INVARIANT-GATES VERDICT TABLE ================
    appconfig-etag-cas   PASS
    blob-worm            PASS
    cosmos-etag-cas      PASS
    ledger-chain         PASS
    lock-clamp           PASS
    queue-capacity       PASS
    test-isolation-leak  FAIL
  ================================================================
  [INVARIANT-GATES] FAIL: 1/7 gate(s) failed.
  ```
  (Exit code: 1)

---

### Finding 7: Compilation Explosion from 22 Distinct `MIX_BUILD_ROOT` Directories

- **Affected Directory**: `/Users/sac/smalt/scripts/shim_court/`
- **Severity**: Medium (Build & CI Performance Impasse)
- **Issue Description**:
  Across the 50 shim court scripts, 22 scripts set private `MIX_BUILD_ROOT` variables:
  `_build-lane272`, `_build-az2`, `_build-lane9`, `_build-lane2`, `_build-lane261`, `_build-lane12`, `_build-bk135r`, `_build-lane291`, `_build-obsfence`, `_build-lane262`, `_build-lane273`, `_build-lane34`, `_build-lane323`, `_build-lane13`, `_build-lane425`, `_build-lane229`, `_build-lane59`, `_build-lane268`, `_build-bk85`, `_build-lane355`, `_build-lane248`, `_build-lane227`, `_build-shim-kafka-sasl`.
  Because `smalt` contains 733 Elixir modules and 91 dependencies, building an isolated build directory requires 4 to 6 minutes of CPU compilation time. Running `just shim-courts` causes dozens of repeated full compilations, taking 30–60+ minutes to execute sequentially.
  While build isolation prevents concurrency collisions, the lack of pre-warmed shared dependencies causes widespread timeouts during automated gate runs.

---

### Finding 8: `scripts/mutation_court.py` Probe Target Staleness

- **Affected File**: `/Users/sac/smalt/scripts/mutation_court.py` (lines 446–492)
- **Severity**: Low / Informational (Target Relocation)
- **Issue Description**:
  `scripts/mutation_court.py` provides 6 source-mutant probes (`cosmos-continuation-forged-check`, `auth-crit-fence`, `blob-if-match-precheck`, `typ-header-fence`, `tee-admit-jti`, `lro-lens9-ownership`).
  While anchor verification (`--probes-self-check`) succeeds for all 6 source anchors in `lib/`, the test suites specified in the probe definitions are pointed at `docs/jira/v26.10.18/burn/test/`:
  ```python
  BURN = "docs/jira/v26.10.18/burn/test"
  PROBES = [
      {"name": "cosmos-continuation-forged-check", "tests": [BURN + "/data_plane/cosmos_test.exs"], ...},
      {"name": "auth-crit-fence", "tests": [BURN + "/auth_enforce_test.exs"], ...},
      ...
  ]
  ```
  These tests live in an archived historical burn corpus from October 2026 rather than active tests under `test/`. The probes test compatibility against archived regression tests rather than the current active test tree.

---

## 4. Live Verification Command Log

| Command Executed | Purpose | Observed Result | Status |
|---|---|---|---|
| `python3 scripts/must_not_migrate_gate.py` | Run sovereign must-not-migrate gate & 6 self-check mutations | Tree clean; F1, F2, F2b, T1a, T1b, T3, T5 mutations all refused on scratch copies; clean tree passes | **PASS** |
| `just posh-invariant-court` | Test POSH SPARQL invariant non-vacuity court | Orphan route injected into scratch TTL; gate flipped to exit 1 naming `invariant_orphan_route.rq`; byte-exact restore | **PASS** |
| `python3 scripts/posh_invariant_gate.py` | Verify active POSH SPARQL queries over merged graph | 2 queries executed; 0 violation rows | **PASS** |
| `python3 scripts/validate_receipt.py --selftest` | Validate receipt provenance anti-vacuity self-test | Legs A, B, and C fired; KD-210 poison SHA refused; lawful receipt admitted | **PASS** |
| `python3 scripts/port_registry_check.py --falsify` | Run port registry falsifier self-test corpus | 19 corpus cases verified | **PASS** |
| `python3 scripts/mutation_court.py --self-check` | Validate GraphLaw validator in-place restore detection | Clean restore verified; corrupted restore detected | **PASS** |
| `python3 scripts/mutation_court.py --probes-self-check` | Verify anchor presence for all 6 mutation probes | All 6 source anchors present exactly once | **PASS** |
| `python3 scripts/posh_mutation_court.py` | Run POSH 8-stage mutation court | Stages 1-5 PASS; Stage 6 crashes (`ModuleNotFoundError: pm4pytest`); Mutant M3 vacuous (`check-ocpq` CLI syntax error) | **FAIL** |
| `bash scripts/live_gate_court.sh` | Run popcorn browser smoke non-vacuity court | Fails with `AssertionError: shim edit did not land` due to SCVD gate code drift in `browser_smoke.mjs` | **FAIL** |
| `python3 scripts/invariant_gates.py` | Run 7 fail-closed invariant gates with negative fixtures | 6 gates PASS (`appconfig-etag-cas`, `blob-worm`, `cosmos-etag-cas`, `ledger-chain`, `lock-clamp`, `queue-capacity`); 1 gate FAILS (`test-isolation-leak`: 108 un-isolated mutations in 75 files) | **FAIL** |
| `bash scripts/shim_court/kafka_vs_aoq_court.sh` | Run kafka vs aoq memory allocation fence court | Fails with `UndefinedFunctionError: Smalt.Planes.resolve/0` due to `--no-compile` on uncompiled build root | **FAIL** |
| `bash scripts/shim_court/amqp_framing_court.sh` | Run AMQP framing connection shim court | Exits code 2 BLOCKED: pyamqp venv missing at `test/sdk-python/.venv-sb/bin/python` | **BLOCKED** |
| `bash scripts/shim_court/disposition_token_court.sh` | Run R201 settlement threading court | Exits code 3 SKIP: subject lacks `lock_token: dlv.lock_token`; `test/amqp/connection_test.exs` missing | **SKIP** |
| `bash scripts/shim_court/corpus_fence_court.sh` | Run dead-citation corpus fence court | Exits code 3 SKIP: `test/corpus_test.exs` deleted at `64f6099` | **SKIP** |

---

## 5. Remediation Action Plan

| ID | Component | Defect Summary | Required Remediation |
|---|---|---|---|
| **REM-01** | `scripts/posh_mutation_court.py` | Mutant M3 calls non-existent `check-ocpq` command | Replace `check-ocpq` with `query` in `cmd_ocpq_mutant`; assert exit 1 and verify TAP `not ok 1 - ocpq_invariants` output. |
| **REM-02** | `scripts/posh_mutation_court.py` & `scripts/enterprise_compliance_court.sh` | Broken `pm4pytest` path (`/Users/sac/ggen-marketplace/...`) | Update path to `/Users/sac/fnox/vendor/pm4pytest/src` or resolve dynamically via `PM4PY_TEST_PATH` / `PYTHONPATH`. |
| **REM-03** | `scripts/live_gate_court.sh` | Regex fails to match updated exit logic in `browser_smoke.mjs` | Update regex in `live_gate_court.sh` to match `const finalExit = ...; process.exit(finalExit);`. |
| **REM-04** | `scripts/shim_court/kafka_vs_aoq_court.sh` | `Smalt.Planes.resolve/0` undefined under `--no-compile` | Ensure `mix compile` runs for `_build-lane59` before invoking `mix run --no-compile`. |
| **REM-05** | `scripts/shim_court/amqp_framing_court.sh` | Missing Python venv at `test/sdk-python/.venv-sb/` | Provision the pyamqp test venv or update the court to use the ambient virtual environment. |
| **REM-06** | `scripts/shim_court/*.sh` (13 courts) | Deleted test files in `test/amqp/` from commit `64f6099` | Restore the missing AMQP test suites from `docs/jira/v26.10.18/burn/test/amqp/` or re-target courts to active integration tests under `test/integration/`. |
| **REM-07** | `gates/test_isolation_leak_gate.py` | 108 un-isolated state mutations across 75 test files | Wrap all `Application.put_env` calls in `put_restored` or capture previous values and restore in `on_exit` callbacks. |
| **REM-08** | `scripts/shim_court/` build architecture | 22 isolated `MIX_BUILD_ROOT` dirs cause cold compile explosion | Seed build roots from a common warm `_build` cache or share compilation artifacts across read-only courts. |

---

## 6. Audit Conclusion & Standing

- **Anti-Vacuity Architecture**: The conceptual design of Smalt's anti-vacuity defenses (requiring negative mutated transcripts to flip verdicts, testing byte-exact restoration, and preventing mock leakage) is robust and follows strict evidence-based engineering.
- **Current Operational Reality**: Multiple active gates fail or vacously pass due to broken import paths, syntax errors in CLI invocations, and extensive test suite rot following the `64f6099` clean-room reset.
- **Recommended Release Gate**: The 8 remediation items above must be resolved before Smalt's mutation courts can serve as an automated, trustworthy gate for production releases.
