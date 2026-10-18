# i21-leak-batch5 — test-isolation leak batch 5 (lane: leak5)

standing: ALIVE
Context: slice (four leased files + leak-court static scan)

## Identity

- repo: /Users/sac/smalt (canonical checkout, branch main @ 558f8c3)
- lane build root: `MIX_BUILD_ROOT=_build-ft-leak5`
- lease: NEXT 4 offender FILES after batch 4's picks; batch4's receipt
  (`i21-leak-batch4.md`) did NOT land within the 10-minute poll window
  (polled 2x10 min; its edits were witnessed on disk mid-flight, build root
  `_build-ft-leak4` present). Collision avoidance therefore done
  mechanically: re-ran the gate, took the first 4 files of the post-batch4
  offender list whose leak flags survived (`_build-ft-leak4` and
  `_build-ft-leak6` roots were active; no file with a same-minute foreign
  mtime was taken — all four leased files were quiescent >15 min).
- files (per lease):
  - `test/arm_cascade_teardown_test.exs` (:36 `smalt.:lro_delay_ms`)
  - `test/arm_cors_test.exs` (:7 `smalt.:arm_cors_origins`)
  - `test/enclave_engine_test.exs` (:22 `smalt.:lro_delay_ms`)
  - `test/enclave_state_test.exs` (:19 `smalt.:lro_delay_ms`)

## Consequences (real diffs)

All four are the same class: `Application.put_env(:smalt, key, value)` in
setup/test body with no save of the previous value. Each got the
tls_test.exs-style conversion:

- single-line save before the mutation
  (`prev_<key> = Application.get_env(:smalt, key)`),
- `on_exit` conditional restore (`put_env` when a previous value existed,
  `delete_env` when it did not).

`test/arm_cors_test.exs` already had an `on_exit` delete (that is why it
flagged "no save of prev value" only) — the delete was replaced by the
save + conditional restore. The other three had no restore at all.

No cross-lane edits were needed; no compile-freeze SLA disclosures.

## Verification ladder (real output)

- Solo runs (`MIX_BUILD_ROOT=_build-ft-leak5`, all exit 0):
  - `test/arm_cascade_teardown_test.exs` — `3 tests, 0 failures`
  - `test/arm_cors_test.exs` — `3 tests, 0 failures` (re-run to capture
    summary; first run's tail was log noise)
  - `test/enclave_engine_test.exs` — `9 tests, 0 failures`
  - `test/enclave_state_test.exs` — `4 tests, 0 failures`
- Gate after edits (exit 1 expected while findings remain):

```
PASS fixture:clean-intact-save-plus-on_exit (expected PASS, scanner said PASS)
PASS fixture:on_exit-stripped (expected REFUSE, scanner said REFUSE; ...)
PASS fixture:literal-restore-no-save (expected REFUSE, scanner said REFUSE; ...)
-- OFFENDERS (33 files, 61 mutations uncovered) --
verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=33 fixtures_refused=True
```

- All four leased files are now absent from the offender list (grep of the
  full offender output returns no match for the four names).
- Negative fixtures still refuse (`fixtures_refused=True`) — anti-vacuity
  intact after the edits.

## Uncovered-count delta

- Lane start (my first gate run, pre-edit): **50 files / 110 mutations**,
  `verdict=FAIL-TREE-LEAKS offenders=50`.
- Lane end: **33 files / 61 mutations**, `offenders=33`.
- Attributable to this lane: **-4 files / -4 mutations** (the four leased
  files; the rest of the delta is concurrent batch4/leak6 lanes landing
  between my two gate runs — their receipts are theirs to file).

## Replay

```
cd /Users/sac/smalt
python3 gates/test_isolation_leak_gate.py | grep -E "arm_cascade_teardown|arm_cors|enclave_engine|enclave_state"   # empty
for f in test/arm_cascade_teardown_test.exs test/arm_cors_test.exs \
         test/enclave_engine_test.exs test/enclave_state_test.exs; do
  MIX_BUILD_ROOT=_build-ft-leak5 mix test "$f"
done
```

## Standing

ALIVE — four solo-green suites with embedded real output; gate re-run
witnesses the four files unflagged and negative fixtures still refusing.
No git (per lease). Build root `_build-ft-leak5` left for coordinator
`lane-clean` at integration.
