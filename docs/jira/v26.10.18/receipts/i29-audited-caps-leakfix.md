# i29: audited_capabilities_test.exs leak-fix (9 ETS sites -> 0)

Context: pair(AZB-20 lane owner + this remediation lane, same checkout
/Users/sac/smalt, disjoint files)

Standing: PASS

## Subject

`test/data_plane/audited_capabilities_test.exs` (untracked, AZB-20 lane's
new file) tripped `gates/test_isolation_leak_gate.py` with 9 uncovered ETS
mutations: the setup block guarded `:ets.new(<literal>, [:named_table, ...])`
for 9 Store tables. Pre-fix md5 `c805ba43ff1bc3539ec666e11734a00e`.

## Change

Removed the 9 guarded `:ets.new` fallbacks. They were dead code:
`SmaltTest.Lifecycle.ensure_store_up/0` bounded-polls until the Store
tables exist (`wait_store_tables`), so the guards never fired when the app
was up — and when they DID fire they minted global named tables from a test
process with no restore (the exact leak class the court flags). The tables
are owned by the tested process (Smalt.Store), satisfying the
"ETS owned by the tested process" discipline; no env/pterm mutations exist
in the file, so `SmaltTest.Env.put_restored` was not needed. All test
bodies/assertions verbatim; no sleeps added (no-sleep doctrine). In-file
comment names this receipt.

## Verification (real output)

```
$ python3 gates/test_isolation_leak_gate.py
-- OFFENDERS: none --
verdict=PASS tree=GREEN offenders=0 fixtures_refused=True
receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json
exit=0
```

```
$ MIX_BUILD_ROOT=_build-ft-aud scripts/fast_test.sh \
    test/data_plane/audited_capabilities_test.exs   # x2
7 tests, 0 failures          (run 1: wall 119s cold build root)
7 tests, 0 failures          (run 2: wall 2s)
exit=0 both runs
```

Owner-collision check: md5 snapshotted before edit (c805ba43...) and
re-read after the green runs (376d9b84d36876c0a4d5cea63f798aac); the delta
is this lane's edit only — no concurrent owner modification reconciled.

Non-vacuity: the gate's negative fixtures (on_exit-stripped,
literal-restore-no-save, put_restored-does-not-launder) all REFUSED in the
same run; positive fixtures PASS. Allowlist untouched — no exemption was
added; the file now passes on its own discipline.
