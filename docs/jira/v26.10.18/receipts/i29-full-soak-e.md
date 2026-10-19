# i29 — Full-Suite Pre-Gate Leg E (full soak, lane build root)

- Date: 2026-10-19
- Repo: /Users/sac/smalt (canonical checkout, no worktrees)
- Command: `MIX_BUILD_ROOT=_build-ft-fse mix test` (cwd /Users/sac/smalt)
- Context: solo(full-suite leg e, fresh _build-ft-fse compile)

## Result

```
1 doctest, 7 properties, 2740 tests, 11 failures, 1 invalid (99 excluded)
Finished in 184.0 seconds (20.0s async, 163.9s sync)
EXIT=2 (mix test wrapper)
```

## Failure classification (11 failures + 1 invalid)

Roster hits this run: **only CrashIsolation boot-contention** (1 invalid).
None of F58-F61, DetsRecovery, DrScenarios, AdversarialJoe, GracefulStop failed.

### Roster (boot-contention)
- **invalid #6: `Smalt.Chaos.CrashIsolationTest` — failure on setup_all callback, all
  tests invalidated.** `eventually("ARM listener answering"): not satisfied within 5000ms
  (after 28 passes) — last value: :retry`
  (test/chaos/crash_isolation_test.exs:34). Boot contention under full-suite load; the
  bounded-poll premise held (typed timeout, no sleep).

### Non-roster (surface regressions present in the tree at HEAD — session did not introduce them; this session made zero edits)
Ten failures, two clusters, both consistent with the in-flight uncommitted lane edits to
`lib/smalt/data_plane/blob_storage.ex` and `lib/smalt/egress_router.ex` visible in
`git status` at this tree:

**Cluster A — GAP-AUD1-01 comp whitelist (BlobHardeningTest, 5 tests)**
test/data_plane/blob_hardening_test.exs:2567/2609/2620/... — unimplemented `comp=` values
(appendblock etc.) answering 200/201 instead of typed 400; duplicate-comp decode no longer
refused.

**Cluster B — container comp fences (EgressWireTest 3 + EgressDispatchTest 2)**
- `HEAD blob comp=blocklist` → 200 fake metadata instead of 400 (egress_wire_test.exs:611)
- container `comp=lease`/`comp=acl` PUT+GET → 200 (empty blob enumeration) instead of 400
  InvalidQueryParameterValue (egress_wire_test.exs:244, 14828; egress_dispatch_test.exs:25947/26016)

**Doc drift (1):** `Smalt.ErrorCodesDocTest` — `docs/ERROR_CODES.md` stale vs sources
(diff shows arm-gateway rows from `lib/smalt/arm_gateway/router.ex`, which is an uncommitted
modified file at this tree). Remedy per test output: `python3 scripts/gen_error_codes.py`.

## Verdict

**NOT GREEN — 11 failures + 1 invalid.** 10/11 non-roster failures are comp-whitelist /
comp-fence regressions already present in the working tree (uncommitted lane edits to
blob_storage.ex / egress_router.ex at this HEAD), plus one doc-drift from the same edit set.
Roster boot-contention contributed 1 invalid (CrashIsolation setup_all poll timeout, 5000ms
budget, 28 passes — contention-class, not a product defect). Zero session-introduced
failures (no edits, no git, no _build deletion performed).

Log preserved: /tmp/fse_full_test.log (full output incl. stacktraces).
