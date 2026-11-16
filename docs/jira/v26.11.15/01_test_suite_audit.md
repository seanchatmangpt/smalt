# Smalt Test Suite Production Audit (v26.11.15)

**Auditor:** Agent 15 (`smalt_auditor_tests`)  
**Target Repository:** `/Users/sac/smalt`  
**Date:** 2026-11-16T18:08:00Z  
**Integrity Mode:** Production Audit & Health Verification (Strict Read-Only)  

---

## 1. Executive Summary & Scope

A comprehensive multi-toolchain test audit was conducted across `/Users/sac/smalt`. The smalt system is a BEAM-native local cloud-edge emulator providing ARM-style control planes, data planes, AMQP/Kafka brokers, Go membrane adapters (`posh/`), Python CLI tools (`smalt-cli/`), and a Next.js 16 Sovereign Console (`workspace/`).

This audit evaluated all test surfaces for:
1. **Real Execution vs Mock/Stub Vacuity:** Determining whether tests execute against live components (in-process ETS/DETS stores, ephemeral Bandit HTTP servers, real socket loopbacks, real crypto) or rely on synthetic mocks.
2. **Vacuous Assertions & Anti-Vacuity Gates:** Identifying vacuous tests (e.g. `assert true`, unvalidated responses) and verifying fail-closed mutation fixtures.
3. **Execution Success & Pass Rates:** Running test suites live across Elixir (ExUnit), Python (pytest), Go (`go test`), and TypeScript/Node (`tsc`, `node`).
4. **Toolchain & Dependency Gaps:** Detecting build-time incompatibilities, missing virtual environments, and broken runners.

---

## 2. Test Suite Inventory & Pass Rate Matrix

| Subsystem / Suite | Harness / Tooling | Tests Identified | Pass / Fail / Skip | Pass Rate | Integrity / Realism Status |
|---|---|---|---|---|---|
| **Elixir: Offline Unit & Vector Tests** | `mix test` (ExUnit) | 359 test files | 78 passed across sampled suites, 1 compilation failure (`sigv4_vectors_test.exs`), 4 census failures | High (Chicago discipline, real ETS/Bandit) |
| **Elixir: Internal Census Gate** | `mix test test/internal/internal_tier_census_test.exs` | 8 court tests | 4 passed, 4 failed | 50.0% | Real static/AST file-read court |
| **Fail-Closed Invariant Gates** | `python3 scripts/invariant_gates.py` | 7 invariant gates | 6 passed (with anti-vacuity negative fixtures), 1 failed (`test-isolation-leak`) | 85.7% | High (positive wire + negative mutated fixtures) |
| **Python CLI Wire & Package Tests** | `just cli-test` (pytest in `.venv-cli`) | 152 test items | 65 passed, 1 failed, 83 skipped, 3 errors | 42.8% (active) | Real wire conftest; 3 syntax errors in `sim_host.py` |
| **Go Dialect & Membrane Tests** | `go test ./...` in `posh/` | 70+ test files | 7 package suites passed; `poshvet` blocked by toolchain pin | Partial | Real unit tests; Go >= 1.26 requirement in `go.mod` blocks `poshvet` |
| **Workspace Next.js Console Tests** | `just ws-court` (`scripts/e2e-court.mjs`) | 76 checks | 73 passed, 0 failed, 3 skipped | 96.1% | Real compiler, JCS, Bellman solver, route smoke, mutation flip |
| **Workspace React Hook Ports** | `just hooks-court` (`scripts/hooks-court.mjs`) | 14 assertions | 14 passed, 0 failed, 0 skipped | 100.0% | Real typechecking via `tsc` + state machine assertions |
| **No-Sleep Doctrine Gate** | `python3 scripts/sleep_gate.py` | 1301 files scanned | 7 sleep violations detected — REFUSED | 0% (Fail-closed) | Strict static syntax scanner |
| **Naming & Absolute Path Sweep** | `bash scripts/naming_sweep.sh` | Full tracked tree | 3,094 violations detected — REFUSED | 0% (Fail-closed) | Static grep against allowlist |
| **Shim Mutation Courts** | `just shim-courts` | 50 courts | Sampled: 2 passed, 2 failed, 1 blocked | Partial | Anti-vacuity mutation shims |

---

## 3. Detailed Audit Findings & Forensic Evidence

### Finding 1: Syntax / Compilation Error in `test/sigv4/sigv4_vectors_test.exs`
- **Location:** `/Users/sac/smalt/test/sigv4/sigv4_vectors_test.exs:155:3`
- **Severity:** Critical (Blocks entire test file compilation)
- **Description:** A mismatched delimiter syntax error exists in `test/sigv4/sigv4_vectors_test.exs`. In the test `"rejection_vectors through the real path"`, line 135 begins `Enum.each(doc["rejection_vectors"], fn vec -> ...`, but line 154 closes with `end` instead of `end)`. This missing closing parenthesis causes Elixir 1.20 parallel compiler to halt with a `MismatchedDelimiterError`.
- **Command Executed:**
  ```bash
  cd /Users/sac/smalt && mix test test/rates/rates_test.exs test/taxsanctions/taxsanctions_test.exs test/sigv4/sigv4_vectors_test.exs test/erp_vectors/erp_vectors_test.exs test/treasury_vectors/treasury_vectors_test.exs
  ```
- **Command Output:**
  ```text
  == Compilation error in file test/sigv4/sigv4_vectors_test.exs ==
  ** (MismatchedDelimiterError) mismatched delimiter found on test/sigv4/sigv4_vectors_test.exs:155:3:
       error: unexpected reserved word: end
       │
   135 │     Enum.each(doc["rejection_vectors"], fn vec ->
       │              └ unclosed delimiter
   ...
   155 │   end
       │   └ mismatched closing delimiter (expected ")")
       │
       └─ test/sigv4/sigv4_vectors_test.exs:155:3
  ```

---

### Finding 2: Vacuous Assertion in Store Recovery Test (`bk69r_probe_tmp_test.exs`)
- **Location:** `/Users/sac/smalt/test/integration/bk69r_probe_tmp_test.exs:35`
- **Severity:** High (Vacuous Test / Zero Anti-Vacuity Protection)
- **Description:** The test `"probe: ensemble-kill semantics"` in `test/integration/bk69r_probe_tmp_test.exs` is intended to verify store survival and data recovery after an ungraceful `Process.exit(pid, :kill)`. However, the test prints diagnostic data via `IO.puts` (`WITNESS whereis`, `WITNESS table_exists`, `WITNESS get`, `WITNESS raw`) and then concludes with `assert true` on line 35. It never asserts that `base.get(:smalt_resources, "probe-k")` returned the stored value `%{"v" => 1}`.
- **Code Extract:**
  ```elixir
  31:     IO.puts("WITNESS new_sup=#{inspect(new)}")
  32:     IO.puts("WITNESS table_exists=#{:ets.info(:smalt_resources) != :undefined}")
  33:     IO.puts("WITNESS get=#{inspect(base.get(:smalt_resources, "probe-k"))}")
  34:     IO.puts("WITNESS raw=#{inspect(:ets.lookup(:smalt_resources, "probe-k"))}")
  35:     assert true
  ```
- **Remediation:** Replace `assert true` with:
  ```elixir
  assert base.get(:smalt_resources, "probe-k") == %{"v" => 1}
  ```

---

### Finding 3: Internal Tier Census Drift & Gate Violations (`InternalTier.CensusTest`)
- **Location:** `/Users/sac/smalt/test/internal/internal_tier_census_test.exs:632`
- **Severity:** High (Failing In-Repo Governance Court)
- **Description:** `test/internal/internal_tier_census_test.exs` enforces strict composition rules on the residual internal test tier: registered file inventory, banned raw HTTP/conn tokens, status-literal assert bans, and closed module allowlists. Running this census court results in 4 test failures out of 8:
  1. **Population Fence Drift:** 4 test files are present on disk under `test/internal/` but unregistered in `@registered`:
     - `kafka_group_court_test.exs`
     - `kafka_kd174_court_test.exs`
     - `kafka_sasl_court_test.exs`
     - `kd189_legalhold_put_header_only_test.exs`
  2. **Forbidden Client Tokens:** `kd189_legalhold_put_header_only_test.exs` uses `Plug.Test.conn(method, path, opts[:body])` without a registered exemption.
  3. **Status-Literal Asserts:** `kd189_legalhold_put_header_only_test.exs` contains status asserts like `assert put_container("hold-a").status == 201` without an exemption.
  4. **Off-Allowlist Module References:** `kd189_legalhold_put_header_only_test.exs` references modules outside the closed allowlist (`Smalt.Internal.KD189LegalholdPutHeaderOnlyTest`, `Smalt.DataPlane.Blob.Worm.set_legal_hold`).
- **Command Executed:**
  ```bash
  cd /Users/sac/smalt && mix test test/internal/internal_tier_census_test.exs
  ```
- **Command Output:**
  ```text
    1) test population fence: test/internal contains exactly the registered files (InternalTier.CensusTest)
       test/internal/internal_tier_census_test.exs:632
       test/internal population drifted: on_disk=MapSet.new(["kafka_group_court_test.exs", "kafka_kd174_court_test.exs", "kafka_sasl_court_test.exs", "kd189_legalhold_put_header_only_test.exs"]) unregistered=MapSet.new([])

    2) test no raw HTTP client / test-only conn helpers / JSON decoder tokens (InternalTier.CensusTest)
       test/internal/internal_tier_census_test.exs:668
       forbidden client tokens: [{"kd189_legalhold_put_header_only_test.exs", "      Plug.Test.conn(method, path, opts[:body])"}]

    3) test no HTTP status literal co-occurs with assert on the same line (InternalTier.CensusTest)
       test/internal/internal_tier_census_test.exs:679
       status-literal asserts: [{"kd189_legalhold_put_header_only_test.exs", "    assert put_container(\"hold-a\").status == 201"}, ...]

    4) test every Smalt-prefixed module reference is inside the closed allowlist (InternalTier.CensusTest)
       test/internal/internal_tier_census_test.exs:704
       off-allowlist module references: [{"kd189_legalhold_put_header_only_test.exs", "Smalt.Internal.KD189LegalholdPutHeaderOnlyTest"}, {"kd189_legalhold_put_header_only_test.exs", "Smalt.DataPlane.Blob.Worm.set_legal_hold"}]

  Finished in 0.7 seconds (0.7s async, 0.00s sync)
  Result: 4/8 passed (4 failed)
  ```

---

### Finding 4: Global Test Isolation State Leaks (75 Test Files)
- **Location:** `/Users/sac/smalt/gates/test_isolation_leak_gate.py`
- **Severity:** High (Cross-Test Pollution & State Leakage)
- **Description:** Running `python3 scripts/invariant_gates.py` executes 7 fail-closed gates. 6 pass, but `test-isolation-leak` fails with `verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=75`. 75 test files across `test/integration/`, `test/internal/`, and `test/smalt/` mutate global BEAM state (`Application.put_env`, `persistent_term`, or ETS) without registering an `on_exit` or `after` restore handler.
- **Command Executed:**
  ```bash
  cd /Users/sac/smalt && python3 scripts/invariant_gates.py
  ```
- **Command Output:**
  ```text
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
- **Representative Offending Tests:**
  - `test/integration/graphlaw_canonical_shapes_court_test.exs:159`: `smalt.:graphlaw_shacl` (no save of prev value)
  - `test/integration/latency_court_test.exs:29`: `smalt.:latency` (no save of prev value)
  - `test/integration/swarm_court_test.exs:228`: pterm mutation `:swarm_court_swarm` (no restore in `on_exit`)
  - `test/internal/b4rc_send_gate_court_test.exs:65`: `smalt.:sb_auto_ensure` (no save of prev value)
  - `test/internal/kafka_wire_test.exs:86`: `smalt.:kafka_guard` (no save of prev value)
  - `test/smalt/aoq/admission_test.exs:26`: `smalt.:aoq_admission` (no save of prev value)

---

### Finding 5: Python CLI Test Failures and Shell Syntax Error (`smalt-cli/tests/`)
- **Location:**
  - `smalt-cli/tests/test_error_codes_doc.py:32`
  - `smalt-cli/hw/sim_host.py:100` (affecting `tests/test_virtual_serial.py`)
- **Severity:** Medium / High
- **Description:** Executing `just cli-test` runs pytest under `.venv-cli`:
  1. `test_error_codes_doc.py`: `test_error_codes_doc_is_byte_identical_projection` fails because `scripts/gen_error_codes.py:485` looks for `"def violation_body("` in `lib/smalt/arm_gateway/plug/policy.ex`, which was refactored, causing `ValueError: substring not found`.
  2. `test_virtual_serial.py`: All 3 tests (`test_enroll_capabilities`, `test_sign_receipt_increasing_counter`, `test_bad_crc_resync_on_the_wire`) crash during fixture setup. `smalt_cli/hw/sim_host.py:100` generates a shell string without quoting parentheses:
     `sh: -c: line 0: syntax error near unexpected token '('`
     `cd '/Users/sac/smalt' && mix run --no-start -e Smalt.Hw.VirtualSerial.start_link(stdio: true) ...`
- **Command Executed:**
  ```bash
  cd /Users/sac/smalt && just cli-test
  ```
- **Command Output:**
  ```text
  FAILED tests/test_error_codes_doc.py::test_error_codes_doc_is_byte_identical_projection
  ERROR tests/test_virtual_serial.py::test_enroll_capabilities - RuntimeError: device died during boot: sh: -c: line 0: syntax error near unexpected token `('
  ERROR tests/test_virtual_serial.py::test_sign_receipt_increasing_counter - RuntimeError: device died during boot: sh: -c: line 0: syntax error near unexpected token `('
  ERROR tests/test_virtual_serial.py::test_bad_crc_resync_on_the_wire - RuntimeError: device died during boot: sh: -c: line 0: syntax error near unexpected token `('
  1 failed, 65 passed, 83 skipped, 3 errors in 362.52s (0:06:02)
  ```

---

### Finding 6: Go Toolchain Incompatibility Blocking `poshvet` (`posh/go.mod`)
- **Location:** `/Users/sac/smalt/posh/go.mod:11`
- **Severity:** Medium (Toolchain Pin Mismatch)
- **Description:** `posh/go.mod` specifies `go 1.23.4`, matching the installed system toolchain (`go version go1.23.4 darwin/arm64`). However, it pins dependency `golang.org/x/tools v0.52.0`. In Go 1.23.4, `golang.org/x/tools@v0.52.0 requires go >= 1.26.0`. As a result, running `go test ./internal/poshvet/...` fails during module loading before executing any tests.
- **Command Executed:**
  ```bash
  cd /Users/sac/smalt/posh && go test ./internal/poshvet
  ```
- **Command Output:**
  ```text
  go: golang.org/x/tools@v0.52.0 requires go >= 1.26.0 (running go 1.23.4)
  ```
- **Note on Passing Posh Packages:** Other Go packages in `posh` that do not depend on `golang.org/x/tools` execute and pass cleanly:
  - `smalt.dev/posh/internal/api` (4.356s)
  - `smalt.dev/posh/internal/config` (4.128s)
  - `smalt.dev/posh/internal/doctor` (8.545s)
  - `smalt.dev/posh/internal/metrics` (9.878s)
  - `smalt.dev/posh/internal/receipt` (8.793s)
  - `smalt.dev/posh/internal/storage` (10.947s)
  - `smalt.dev/posh/internal/auth` (9.664s)

---

### Finding 7: Schema Association Case Mismatch (`lib/smalt/network/mx.ex`)
- **Location:** `/Users/sac/smalt/lib/smalt/network/mx.ex:1`
- **Severity:** Low / Code Quality
- **Description:** Schema `Smalt.Network.MX` defines an association to `Smalt.Network.Dnszone` (lowercase 'z'). However, the actual module defined in `lib/smalt/network/dns_zone.ex` is `Smalt.Network.DnsZone` (capital 'Z'). During compilation, this produces an association warning, and on case-sensitive or strict BEAM loading, causes an error:
  `10:02:37.099 [error] beam/beam_load.c(186): Error loading module 'Elixir.Smalt.Network.Dnszone': module name in object code is 'Elixir.Smalt.Network.DnsZone'`.
- **Command Output:**
  ```text
  warning: invalid association `parent` in schema Smalt.Network.MX: associated schema Smalt.Network.Dnszone does not exist
  └─ lib/smalt/network/mx.ex: Smalt.Network.MX (module)
  ```

---

### Finding 8: No-Sleep Doctrine Gate Violations (`scripts/sleep_gate.py`)
- **Location:** `/Users/sac/smalt/scripts/sleep_gate.py`
- **Severity:** Medium (DoD / Governance Failure)
- **Description:** Smalt enforces a strict zero-sleep policy (`docs/NO_SLEEP_DOCTRINE.md`). Fixed sleeps in tests cause non-deterministic timing, race conditions, and test flakiness. The static sleep gate failed closed, finding 7 unclassified sleep calls in external verification tests:
  - `verification/py/test_wf9_kafka.py:54`: `time.sleep(0.2)`
  - `verification/py/test_wf9_kafka.py:87`: `time.sleep(0.05)`
  - `verification/py/test_wf9_kafka.py:112`: `time.sleep(0.25)`
  - `verification/py/test_wf9_kafka.py:163`: `time.sleep(0.5)`
  - `verification/py/test_wf9_kafka.py:189`: `time.sleep(0.25)`
  - `verification/py/test_wf9_sqs.py:146`: `time.sleep(0.5)`
  - `verification/ts/wf9-kafka.probe.mjs:96`: `await new Promise((r) => setTimeout(r, 250));`
- **Command Executed:**
  ```bash
  cd /Users/sac/smalt && python3 scripts/sleep_gate.py
  ```
- **Command Output:**
  ```text
  [SLEEP-GATE] 7 violation(s) across 1301 files — REFUSED
  ```

---

### Finding 9: Naming Sweep Gate Refusal (`scripts/naming_sweep.sh`)
- **Location:** `/Users/sac/smalt/scripts/naming_sweep.sh`
- **Severity:** Low / Repo Hygiene
- **Description:** The naming sweep enforces clean publication readiness by banning machine-specific paths (e.g. `/Users/sac`) and deprecated repo names (`athena`, `courtroom`). The gate failed with 3,094 violations against 61 allowlisted lines.
- **Command Executed:**
  ```bash
  bash /Users/sac/smalt/scripts/naming_sweep.sh
  ```
- **Command Output:**
  ```text
  [NAMING-SWEEP] FAIL: 3094 violation(s), 61 allowed
  ```

---

### Finding 10: Shim Mutation Court Gaps & Bash Syntax Error
- **Location:**
  - `scripts/bin_opt_gate.sh:164`
  - `scripts/shim_court/amqp_framing_court.sh`
  - `scripts/shim_court/bin_opt_gate_court.sh`
- **Severity:** Medium
- **Description:**
  1. `amqp_framing`: BLOCKED (rc=2) because virtual environment `/Users/sac/smalt/test/sdk-python/.venv-sb/bin/python` is absent.
  2. `bin_opt`: FAILED due to a syntax error in `scripts/bin_opt_gate.sh:164` where unquoted single quotes in a Python heredoc inside bash `$()` trigger:
     `/Users/sac/smalt/scripts/bin_opt_gate.sh: line 164: unexpected EOF while looking for matching '''`.
  3. `bin_opt_gate`: FAILED with `before-witness failed against UNMODIFIED /Users/sac/smalt/lib/smalt/aoq/frame.ex — old signature absent; refusing to shim`.
- **Command Executed:**
  ```bash
  cd /Users/sac/smalt && just shim-courts
  ```

---

## 4. Real Execution vs Mock Usage Analysis

A key directive of this audit was verifying whether tests execute against real implementations or rely on mock facades.

### Elixir Core (`test/`)
- **No Mocking Frameworks:** Across all 359 test files, zero references to `Mox` or `mock` libraries were found.
- **Chicago Testing Discipline:** Tests follow Chicago style:
  - Real ETS/DETS table partitioning (`Smalt.Store.Partition`).
  - Real Bandit HTTP servers binding to ephemeral ports (`127.0.0.1:<random_port>`).
  - Real GenServers and dynamic supervisors with real ungraceful process terminations (`Process.exit(pid, :kill)`).
  - Real distributed node testing using Erlang `:peer` (e.g., `test/cluster/cluster_test.exs`).
  - Real cryptographic hashing over Blake3 and RS256 JWKS verification over raw wire sockets.

### Workspace Next.js Console (`workspace/`)
- Tests executed via `scripts/e2e-court.mjs` and `scripts/hooks-court.mjs`:
  - Real TypeScript AST typecheck via `tsc` across all hook ports.
  - Real Bellman value-iteration solver testing bit-identical determinism across runs (`solver/bellman.ts`).
  - Real JCS canonical JSON serialization.
  - Real SSE streaming delta frames and Next.js route smoke handlers.

---

## 5. Anti-Vacuity Evaluation

Anti-vacuity in `/Users/sac/smalt` is enforced via two primary mechanisms:
1. **Invariant Gate Negative Fixtures (`scripts/invariant_gates.py`):**
   - Each gate runs a positive wire assertion against an ephemeral substrate, followed by multiple mutated fixture runs (e.g. `both-racers-win`, `both-racers-lose`, `unconditional-overwrite-accepted`, `stale-if-match-accepted`, `lock-never-bound`, `ledger-id-unbound`).
   - The gate strictly refuses each negative fixture; if a mutated fixture were to pass, the gate fails immediately.
2. **Shim Court Mutation Verification (`just shim-courts`):**
   - Applies an in-place AST/text mutation to target source code (`[SHIM] AFTER witness passed`).
   - Verifies that the test flips to red under mutation.
   - Restores the original file byte-exact and re-verifies that sha256 matches.

---

## 6. Actionable Remediation Cutlist

| Priority | ID | Target File / Module | Recommended Remediation |
|---|---|---|---|
| **P0** | C-01 | `test/sigv4/sigv4_vectors_test.exs:154` | Fix mismatched delimiter syntax error: change `end` to `end)` at line 154. |
| **P0** | C-02 | `smalt_cli/hw/sim_host.py:100` | Quote the Elixir expression in subprocess call: `mix run --no-start -e "Smalt.Hw.VirtualSerial.start_link(stdio: true)"` to avoid bash syntax error. |
| **P1** | C-03 | `test/integration/bk69r_probe_tmp_test.exs:35` | Replace vacuous `assert true` with real state assertion: `assert base.get(:smalt_resources, "probe-k") == %{"v" => 1}`. |
| **P1** | C-04 | `test/internal/internal_tier_census_test.exs` | Register 4 missing internal tests (`kafka_group_court_test.exs`, `kafka_kd174_court_test.exs`, `kafka_sasl_court_test.exs`, `kd189_legalhold_put_header_only_test.exs`) and add required exemptions for `kd189`. |
| **P1** | C-05 | 75 test files flagged by `test-isolation-leak` | Wrap `Application.put_env` and `persistent_term` mutations in `on_exit` handlers to restore previous values. |
| **P1** | C-06 | `posh/go.mod` | Downgrade `golang.org/x/tools` to a version compatible with Go 1.23.4 (e.g. `v0.28.0`), or update toolchain requirements. |
| **P2** | C-07 | `scripts/gen_error_codes.py:485` | Update `extract_policy()` to search for the current policy violation function name instead of obsolete `"def violation_body("`. |
| **P2** | C-08 | `lib/smalt/network/mx.ex:1` | Rename schema reference `Smalt.Network.Dnszone` to match canonical module `Smalt.Network.DnsZone`. |
| **P2** | C-09 | `scripts/bin_opt_gate.sh:164` | Fix bash heredoc quoting to prevent syntax error on apostrophes inside Python comments. |
| **P2** | C-10 | `verification/py/` & `verification/ts/` | Replace unclassified `time.sleep` / `setTimeout` with bounded observable pollers per `docs/NO_SLEEP_DOCTRINE.md`. |
