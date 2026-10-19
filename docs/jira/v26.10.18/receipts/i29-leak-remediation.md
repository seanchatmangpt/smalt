# i29-leak-remediation — test-isolation leak court remediation (slice)

Context: slice(leak-court remediation)
Date: 2026-10-18
Lane: leak-court remediation, repo /Users/sac/smalt

## Standing

PASS (gate green: offenders 17 files / 39 mutations → 0; positive fixtures
still refuse — non-vacuous). Test runs for both edited files green.

## Before / After (measured)

```
$ python3 gates/test_isolation_leak_gate.py
== test-isolation-leak court ==
scanned 170 .exs files under test/ (1 allowlisted)
-- OFFENDERS (17 files, 39 mutations uncovered) --
verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=17 fixtures_refused=True
```

```
$ python3 gates/test_isolation_leak_gate.py
== test-isolation-leak court ==
scanned 170 .exs files under test/ (17 allowlisted)
-- OFFENDERS: none --
verdict=PASS tree=GREEN offenders=0 fixtures_refused=True
```

Positive-control non-vacuity held across both runs: `on_exit-stripped` and
`literal-restore-no-save` fixtures both REFUSED.

## What changed

### Code fixes (scanner-visible save/restore discipline; assertions preserved verbatim)

1. `test/azsim/identity_plane_test.exs` ("accessors read the profile keys
   with byte-identical defaults"):
   the `SmaltTest.Env.with` wrapper hid the two
   `Application.delete_env(:smalt, :keyvault/:sts)` calls from the scanner
   and `Env.with` cannot express deletion (assertions demand TRUE absence —
   `Smalt.Config.sts() == []`, `Smalt.Config.keyvault()` default `[]` would
   not match nil). Rewritten as explicit save + on_exit restore +
   delete-then-assert. Assertions byte-identical.

2. `test/security/security_hardening_test.exs` maa capture-and-delete test
   (was `put_restored` + bare delete): the restore was invisible to the
   scanner ("no save of prev value"). Rewritten as explicit
   save + on_exit restore + test-scoped delete. Assertion preserved.

3. `test/security/security_hardening_test.exs` ledger fence helper:
   `restore_ledger_enforce_existence/1` deleted; its 4 after-block callers
   now inline the literal `prior`-keyed restore inside the `after` blocks,
   and the one mid-test flip (`restore_ledger_enforce_existence(nil)`)
   became a direct `Application.delete_env(:smalt, :ledger_enforce_existence)`
   (save via the existing `prior = Application.get_env(...)` binding).
   Semantics identical (nil-preserving restore, save-first).

### Named allowlist additions (gate's own mechanism; whole-file, per-file justification embedded as comments in `gates/test_isolation_leak_gate.py`)

Scanner cannot express the restore forms used; discipline hand-verified on
2026-10-18 by reading each site (no gate rules changed beyond the ALLOWLIST
set):

- variable-key restore helpers / on_exit shields:
  `test/auth_enforce_test.exs`, `test/lro_test.exs`,
  `test/trust_profile_test.exs` (also pterm tuple keys restored in try/after)
- for-loop variable-key port pins restored via
  `SmaltTest.PortEnv.restore(prev_ports)` + `Lifecycle.restore_app/0`:
  `test/canonical_projection_test.exs`
- pterm module-scoped tuple keys `{__MODULE__, ...}`:
  `test/kv_tls_test.exs`, `test/compliance/c3_cosmos.exs`,
  `test/compliance/c4_blob.exs`, `test/amqp/fuzz_test.exs`
- ets.new with `@table`/variable table names, every created table deleted
  in on_exit: `test/store_dets_test.exs`,
  `test/store_dets_growth_test.exs`,
  `test/azsim/dets_recovery_test.exs`,
  `test/data_plane/audit_planes_test.exs`
- module-body shifted-port boot config (test_helper-class, guarded by
  `:ets.info(:smalt_blobs)`): `test/data_plane/blob_service_test.exs`
- pterm `{Smalt.TrustProfile, :keypair}` copy erased in try/after:
  `test/security/security_hardening_test.exs`
- boot script in its own BEAM (no test process to leak into):
  `test/sdk-full/azb20/boot_plane.exs`
- put_env inside a heredoc subprocess SCRIPT (separate BEAM, zero
  test-VM leak): `test/azsim/data_plane_test.exs`

## Verification

```
$ python3 gates/test_isolation_leak_gate.py; echo exit=$?
verdict=PASS tree=GREEN offenders=0 fixtures_refused=True
exit=0
```

```
$ scripts/fast_test.sh test/azsim/identity_plane_test.exs   # private build root _build-ft-bb371b51
12 tests, 0 failures

$ scripts/fast_test.sh test/security/security_hardening_test.exs
65 tests, 0 failures
```

## Falsifier / residual risk

- The allowlist is whole-file. If a future mutation is added to an
  allowlisted file, the gate still reports the file as ALLOWED (mutation
  counts are printed per file, so growth is visible in the gate output).
- `Env.with([k: :__unset__])` does not delete keys; the
  identity_plane rewrite removed the only place that pattern was combined
  with real deletes — no other caller combines them.
- The mid-test fence flip now relies on nil ≡ absent: confirmed for this
  key (`Application.get_env(:smalt, :ledger_enforce_existence, false)` —
  stored nil is falsy, same branch as absent). If a reader ever compares
  `== false` literally, re-add an explicit delete.
