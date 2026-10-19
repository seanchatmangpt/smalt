# i29 — Court Surfaces Receipt

Date: 2026-10-19 · Lane: bench-runner · Scope: read-only court runs, no edits, no git.
Standing: **PARTIAL_ALIVE** (2 PASS, 1 typed DEFICIT, 1 FAIL-TREE-LEAKS — honest, not green-washed).
Context: slice(just sleep-gate, isolation-court, leak-court-count court surfaces)

## 1. `just sleep-gate`

```text
[SLEEP-GATE] PASS — 334 files, 0 unclassified sleep primitives
```

Standing: **PASS**.

## 2. `just isolation-court` (AZB-11)

```text
== isolation court (AZB-11) ==
scanned 169 test module files
PASS fixture:clean-put_restored (expected PASS, scanner PASS)
PASS fixture:bare-put_env (expected REFUSE, scanner REFUSE); 5 env mutation
  `smalt.:probe_key` (no save of prev value)
PASS fixture:named-start_link (expected REFUSE, scanner REFUSE); 5 start_link in
  test body must be start_supervised!/1 (Agent.start_link(fn -> :ok end, name: :iso_court_leaked_name)
PASS fixture:exempt-honored (expected PASS, scanner PASS)
-- OFFENDERS: none --
verdict=PASS static=GREEN fixtures=REFUSED-OK elapsed=0.70s
```

Standing: **PASS** (fixtures REFUSED-OK — non-vacuity witnessed).

## 3. `just leak-court-count`

```text
[LEAK-COURT] exit=1 1 uncovered-mutation lines (see /tmp/leak-court.out)
```

Full court output (`/tmp/leak-court.out`):

```text
== test-isolation-leak court ==
scanned 170 .exs files under test/ (1 allowlisted)
PASS fixture:clean-intact-save-plus-on_exit (expected PASS, scanner said PASS)
PASS fixture:on_exit-stripped (expected REFUSE, scanner said REFUSE; L6 env mutation
  `smalt.:probe_key` (no restore in on_exit/after))
PASS fixture:literal-restore-no-save (expected REFUSE, scanner said REFUSE; L8 env mutation
  `smalt.:probe_key` (no save of prev value))
ALLOWED test/tls_test.exs (4 tracked mutations, exempt: hand-verified restore)
-- OFFENDERS (17 files, 39 mutations uncovered) --
  test/security/security_hardening_test.exs:328 env mutation `smalt.:maa_measurement_baseline` (no save of prev value)
  test/security/security_hardening_test.exs:858 env mutation `smalt.:ledger_enforce_existence` (no restore in on_exit/after)
  test/sdk-full/azb20/boot_plane.exs:20 env mutation `smalt.:planes` (no save of prev value)
  test/sdk-full/azb20/boot_plane.exs:46 env mutation `smalt.:sb_endpoint` (no save of prev value)
  test/sdk-full/azb20/boot_plane.exs:49 env mutation `smalt.:sb_shared_key` (no save of prev value)
  test/azsim/data_plane_test.exs:276 env mutation `smalt.:blob_storage` (no save of prev value)
  test/azsim/identity_plane_test.exs:126 env mutation `smalt.:keyvault` (no save of prev value)
verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=17 fixtures_refused=True
receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json
```

Standing: **FAIL-TREE-LEAKS** (typed). 17 offender files / 39 uncovered mutations
(output truncates the offender list to 7 of 17). Fixtures themselves refuse
correctly (`fixtures_refused=True`) — the gate is non-vacuous; the tree has real
leaks. This is a pre-existing tree state, not session-introduced (no edits made).

## 4. `scripts/have/pool_saturation_guard.py --target-pool 20`

```json
{"deficit": 5, "severity": "SEV4", "status": "DEFICIT", "target_pool": 20, "ts": "2026-10-19T04:45:48Z", "workers": 15}
```

Standing: **DEFICIT** (typed, SEV4). 15/20 workers observed; deficit 5. Guard
exits with a typed status rather than faking saturation.

## Machine

Not re-measured this lane (no timing surfaces in scope beyond isolation-court's
internal `elapsed=0.70s`). `just bench-machine` output was not captured for this
receipt — court lanes, not perf lanes.

## Summary

| Surface | Verdict |
|---|---|
| sleep-gate | PASS (334 files, 0 unclassified) |
| isolation-court (AZB-11) | PASS, fixtures REFUSED-OK |
| leak-court-count | FAIL-TREE-LEAKS (17 files / 39 mutations; gate non-vacuous) |
| pool-saturation-guard | DEFICIT SEV4 (15/20, deficit 5) |

Falsifier for this receipt: re-run any of the four; typed outputs must reproduce.
