# i26 — AZB-11b residue closure: sweeper-grace contention flake quiet-clean x3

Standing: **ALIVE** (residue closed)
Context: solo(AZB-11b sweeper-grace flake site, quiet-clean x3)

## Subject

- Repo: /Users/sac/smalt @ main (effd877, tree carries uncommitted AZB-11b remediation edits per git status)
- Test: `test/affidavit_wasm_failclosed_test.exs`
- Build root: `_build-ft-f11q`

## Fence inventory (verified on disk before runs)

- fence 10 — "restart hammer under parallel load" (line 549)
- fence 11 — "supervised-restart hammer — kill-loop under load stays typed, engine returns" (line 657)
- fence 12 — "start while running is typed already_started passthrough" (line 759)

All three present. 14 tests total in file.

## Verification (3x consecutive quiet runs, 2026-10-18)

```
=== RUN 1 ===
Finished in 9.2 seconds (0.00s async, 9.2s sync)
14 tests, 0 failures

=== RUN 2 ===
Finished in 8.0 seconds (0.00s async, 8.0s sync)
14 tests, 0 failures

=== RUN 3 ===
Finished in 8.3 seconds (0.00s async, 8.3s sync)
14 tests, 0 failures
```

Zero failures, zero errors across all 3 runs; no flake observed. The
previously reported sweeper-grace contention flake did not reproduce —
including fence 11 (the kill-loop-under-load leg that observed the
original `EXIT noproc` shake witness noted at line 39 of the file).

## Verdict

AZB-11b residue **closes**: quiet-clean x3 on the current tree with
fences 10/11/12 all present and executing.

## Environment

- cpu: Apple M3 Max, cores: 16, ram_gb: 48, elixir: 1.19.5, otp: 28, darwin: 26.2
- No edits, no git operations performed (solo lane, verify-only).
