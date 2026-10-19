# i28 — Sleep Gate Full Verification (Current Tree)

Standing: PASS
Context: solo(python3 scripts/sleep_gate.py --as=test / --as=lib + shim court; no mix test invocation)

Date: 2026-10-18. Scope: verify the sleep gate on the current tree as run by
`bench-runner` (gate-lane, context: gates). No edits, no git operations.

## Runs

- `python3 scripts/sleep_gate.py --as=test`
  → `[SLEEP-GATE] PASS — 333 files, 0 unclassified sleep primitives`, exit 0.
- `python3 scripts/sleep_gate.py --as=lib`
  → `[SLEEP-GATE] PASS — 333 files, 0 unclassified sleep primitives`, exit 0.

Note: the scanner output reports the same scanned-file count (333) for both
profiles; the profile-specific counts differ only in the classified-sleep
dimension, which the summary line does not print. Unclassified = 0 in both.

## Court (4/4 legs)

`just sleep-gate-court`, exit 0:

1. test-leg subject shim — PASS (BEFORE old-signature, AFTER new-outcome,
   restore byte-exact sha256 a8131e22…)
2. lib-leg subject shim — PASS (restore byte-exact sha256 3822b865…)
3. burn subject `docker/burn/.shim_court_subject.sh` — PASS (restore byte-exact
   sha256 0bce180c…)
4. dual-naming subject `docker/burn/.shim_court_subject2.sh` — PASS (restore
   byte-exact, same baseline sha256 0bce180c…)

Self-check: sha256 restore-detection verified before legs ran. Final verdict:
`[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (test + lib +
burn + dual-naming), restore byte-exact`.

## Counts

- Unclassified sleep primitives, `--as=test`: 0 (PASS)
- Unclassified sleep primitives, `--as=lib`: 0 (PASS)
- Court legs passed: 4/4; injected-sleep refusals: 4; restores byte-exact: 4.
- Errors/failures: none.
