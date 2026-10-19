# i29 leak-gate put_restored recognition

- Date: 2026-10-18
Context: solo
- Subject: `gates/test_isolation_leak_gate.py` @ main (pre-edit tree), scope `test/**/*.exs` static scan
- Standing: **ALIVE**

## Change (gate only; no test/ edits by this lane)

Scanner now recognizes `SmaltTest.Env.put_restored(kvs)` call sites as
covered save+restore. Verified first against `test/support/env.ex`:
`put_restored/1` saves prev per key (`Application.get_env(:smalt, k, @unset)`)
and registers a nil-preserving `on_exit` restore (delete when unset, put when
present) — receipted discipline, so a call site covers each literal keyword
key in its list.

Implementation: paren-matched extraction of the call's keyword list; literal
keys (`key:` form only, so atom values like `:enforce` never over-cover) are
added to a `pr_covered` set consulted in the env coverage check. Also added
two fixtures to `run_fixtures`:

- positive `put_restored-site-covered`: helper site must be found GREEN
  (proves the recognition is not dead).
- negative `put_restored-does-not-launder-raw-put_env`: a save-less raw
  `Application.put_env` in a file that also uses put_restored stays REFUSED
  (recognition cannot launder other mutations).

Allowlist retirement (ERRC): `test/lro_test.exs` entry went STALE-ALLOWLIST
(0 tracked mutations) once recognition landed — its discipline is now
expressible, so the exemption is removed with a RETIRED comment in place.

## Verification (actual output)

```
python3 gates/test_isolation_leak_gate.py
scanned 171 .exs files under test/ (17 allowlisted)
-- positive: KNOWN-clean discipline fixtures --
PASS fixture:clean-intact-save-plus-on_exit (expected PASS, scanner said PASS)
PASS fixture:put_restored-site-covered (expected PASS, scanner said PASS)
PASS fixture:put_restored-does-not-launder-raw-put_env (expected REFUSE, scanner said REFUSE; L6 env mutation `smalt.:probe_key` (no save of prev value))
PASS fixture:on_exit-stripped (expected REFUSE, scanner said REFUSE; L6 env mutation `smalt.:probe_key` (no restore in on_exit/after))
PASS fixture:literal-restore-no-save (expected REFUSE, scanner said REFUSE; L8 env mutation `smalt.:probe_key` (no save of prev value))
-- OFFENDERS: none --
verdict=PASS tree=GREEN offenders=0 fixtures_refused=True receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json
EXIT=0
```

Offender count: **0 files / 0 mutations** (was 4 flagged in-flight files, all
put_restored users; raw `put_env` sites would stay flagged — none remain
outside the 17 hand-verified allowlist exemptions).

Machine receipt JSON: `/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json`.

## Lane C coordination

`git diff --stat test/ | tail -1`:
- before gate edit: `10 files changed, 61 insertions(+), 164 deletions(-)`
- after gate edit + gate runs: `11 files changed, 149 insertions(+), 289 deletions(-)`

The count changed mid-run (Lane C owns test/ and was actively editing). This
lane's diff is confined to `gates/test_isolation_leak_gate.py` and this
receipt; the final scan ran against Lane C's mid-flight tree, so the GREEN
tree verdict is as-of this run's snapshot.

## Falsifier

A file using `put_restored` still flagged, or the new negative fixture
passing, would falsify the recognition. Neither observed: exit 0 with all
five fixtures in expected verdicts.
