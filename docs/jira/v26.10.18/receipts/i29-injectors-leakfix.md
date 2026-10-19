# i29 — injectors leak-gate resolution (allowlist, 25b844f pattern)

Date: 2026-10-18 · Context: solo(smalt @ /Users/sac/smalt, branch main, no git actions)
Standing: PASS (gate green for the subject file; tree FAIL is other lanes' in-flight files)

## Subject

`test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs` (committed 19a420a),
flagged by `python3 gates/test_isolation_leak_gate.py` at the `save_env/2` helper
(`Application.put_env(:smalt, key, value)` + on_exit restore, lines 64–78).
Gate change: `gates/test_isolation_leak_gate.py` ALLOWLIST entry only. Zero test edits.

## Hand verification of the env harness

- `prev` captured via `Application.get_env(:smalt, key, :__unset__)` BEFORE each
  `Application.put_env`; on_exit restores put/delete keyed on `:__unset__` sentinel
  (nil-preserving).
- **LIFO ordering verified empirically**, not assumed: a standalone probe mix project
  registered an observer on_exit FIRST (runs LAST) plus 3 stacked `save_env` calls on
  one key — final env value after all restores = the original (`final=orig`,
  /tmp/leakprobe run, 1 test 0 failures). Stacked `:sts_clock` saves (x3 in test 1)
  unwind correctly.
- Crash safety: ExUnit runs on_exit callbacks on test failure — no missing path.
- All 6 assertions across both JWT tests verbatim; no restructure needed.

## Evidence

```
$ python3 gates/test_isolation_leak_gate.py   # BEFORE
-- OFFENDERS (3 files, 6 mutations uncovered) --
  test/arm_cors_test.exs:28 ...
  test/amqp/sas_verifier_test.exs:231 ...
  test/amqp/sas_verifier_test.exs:268 ...
verdict=FAIL-TREE-LEAKS offenders=3 fixtures_refused=True
(stdout list truncated; receipt json offender_files also includes
 test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs)
scanner on subject file: {"mutations": 3, "offenders": [], "verdict": "REFUSE"}  # unresolved variable keys

$ python3 gates/test_isolation_leak_gate.py   # AFTER (allowlist entry added)
scanned 171 .exs files under test/ (18 allowlisted)
ALLOWED test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs (3 tracked mutations, exempt: hand-verified restore)
-- OFFENDERS (3 files, 4 mutations uncovered) --
  test/arm_cors_test.exs:28 ...
  test/amqp/frame_codec_test.exs:769 ...
  test/amqp/sas_verifier_test.exs:231/268 ...
verdict=FAIL-TREE-LEAKS fixtures_refused=True
```

- Positive fixtures still refusing (3/3 ok) — gate non-vacuity intact.
- Behavior: `MIX_BUILD_ROOT=_build-lane-i29leak mix test
  test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs --include stress`
  → `6 tests, 0 failures` (0.3s). No behavioral change; assertions untouched.

## Residuals

- Tree verdict remains FAIL-TREE-LEAKS on files owned by concurrent lanes
  (arm_cors_test.exs, sas_verifier_test.exs, frame_codec_test.exs — the last appeared
  mid-session). Out of this lane's scope; not touched.
- Lane build root `_build-lane-i29leak` left in tree (rm denied in lane scope) —
  coordinator `just lane-clean` reclaims it.
