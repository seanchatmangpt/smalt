# Receipt — i29 (isolation courts, advisory count run)

- **Subject**: `/Users/sac/smalt` working tree, 2026-10-18
- **Context**: solo(just isolation-court; just leak-court-count; isolation-court-runtime SKIP-foreign-port-holder)
- **Standing**: PARTIAL_ALIVE — static courts advisory-run only; runtime twin skipped (foreign port holder); no edits, no git (count lane).

## Commands + real output

### 1. `just isolation-court` (static) — exit 0

```
== isolation court (AZB-11) ==
scanned 169 test module files

-- fail-closed fixtures --
PASS fixture:clean-put_restored (expected PASS, scanner PASS)
PASS fixture:bare-put_env (expected REFUSE, scanner REFUSE); 5 env mutation `smalt.:probe_key` (no save of prev value)
PASS fixture:named-start_link (expected REFUSE, scanner REFUSE); 5 start_link in test body must be start_supervised!/1 (Agent.start_link(fn -> :ok end, name: :iso_court_leaked_name)
PASS fixture:exempt-honored (expected PASS, scanner PASS)

-- OFFENDERS: none --

verdict=PASS static=GREEN fixtures=REFUSED-OK elapsed=1.00s
EXIT=0
```

### 2. `just leak-court-count` — advisory (gate itself exit 1, tree still leaks)

```
[LEAK-COURT] exit=1 1 uncovered-mutation lines (see /tmp/leak-court.out)
```

Full scanner output (`/tmp/leak-court.out`, 17 lines):

```
== test-isolation-leak court ==
scanned 170 .exs files under test/ (1 allowlisted)

-- positive: KNOWN-clean discipline fixtures --
PASS fixture:clean-intact-save-plus-on_exit (expected PASS, scanner said PASS)
PASS fixture:on_exit-stripped (expected REFUSE, scanner said REFUSE; L6 env mutation `smalt.:probe_key` (no restore in on_exit/after))
PASS fixture:literal-restore-no-save (expected REFUSE, scanner said REFUSE; L8 env mutation `smalt.:probe_key` (no save of prev value))

-- allowlist --
ALLOWED test/tls_test.exs (4 tracked mutations, exempt: hand-verified restore)

-- OFFENDERS (17 files, 39 mutations uncovered) --
  test/security/security_hardening_test.exs:328 env mutation `smalt.:maa_measurement_baseline` (no save of prev value)
  test/security/security_hardening_test.exs:858 env mutation `smalt.:ledger_enforce_existence` (no restore in on_exit/after)
  test/sdk-full/azb20/boot_plane.exs:20 env mutation `smalt.:planes` (no save of prev value)
  test/sdk-full/azb20/boot_plane.exs:46 env mutation `smalt.:sb_endpoint` (no save of prev value)
  test/sdk-full/azb20/boot_code.exs:49 env mutation `smalt.:sb_shared_key` (no save of prev value)
  test/azsim/data_plane_test.exs:276 env mutation `smalt.:blob_storage` (no save of prev value)
  test/azsim/identity_plane_test.exs:126 env mutation `smalt.:keyvault` (no save of prev value)
  ... (10 further rows in /tmp/leak-court.out)

verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=17 fixtures_refused=True receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json
```

(Exact lines reproduced where shown; full 17-row table in /tmp/leak-court.out
and the JSON receipt. The `leak-court-count` recipe reports the "uncovered"
line count as 1 because only the summary line contains the word "uncovered" —
the authoritative uncovered-mutation count is the scanner's own
"39 mutations uncovered" figure.)

### 3. `just isolation-court-runtime` — SKIP (loud)

```
SKIP: ports 9443/8443/5672 held by a foreign process, not the smalt substrate:
  PID 61023 ppid 1 — ssh: /Users/sac/.colima/_lima/colima/ssh.sock [mux] (colima/lima VM port forwards)
Per lane instructions the runtime twin is not run against a foreign port
holder; no eviction attempted.
```

## Trend vs last recorded figures

- **leak-court** (vs `docs/jira/v26.10.17/receipts/i20e-leak-court.md`,
  2026-10-17: 56 files / 122 mutations uncovered, 153 .exs scanned):
  now **17 files / 39 mutations** (170 .exs scanned). **DOWN** —68% mutations
  (122→39), -39 files. Remediation slices from i20e and the AZB-11 lane
  (58/61 env sites fixed via `SmaltTest.Env.put_restored/1`) are visible in
  the count. Gate still exit 1 → stays advisory, correctly not wired into
  `just court`.
- **isolation-court static** (vs `docs/jira/v26.10.18/receipts/azb-11-isolation-court.md`,
  AZB-11: static GREEN, 153 modules scanned, OFFENDERS: none): now
  **PASS / static GREEN / OFFENDERS: none, 169 modules scanned**. **FLAT** —
  still green as tree grew 153→169 modules; no regression.

## Deviations

- Runtime twin skipped: foreign port holder (colima ssh mux), per lane rule.
- `just leak-court-count`'s grep-based "1 uncovered-mutation lines" summary
  undercounts; the scanner's own offender table is ground truth (39).
