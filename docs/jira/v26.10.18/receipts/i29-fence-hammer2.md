# Receipt: i29 fence-10/11/12 triple hammer ×10, re-run at post-wrap HEAD

- Date: 2026-10-18
- Context: slice(fence ×10)
- Standing: PASS (10/10 identical green)
- Subject: `/Users/sac/smalt` @ 806d86e0c29695155de7dada67dd3c74098b9c16 (working tree, shared machine)

Re-run of `docs/jira/v26.10.18/receipts/i29-fence-hammer.md` (which was taken at
6eec145) after the Bandit `shutdown:10_000` wrap and atom_bridge fix landed
(HEAD ≥ 806d86e).

## Subject identification

All three fences live in one file (per the prior receipt's mapping):

- `test/affidavit_wasm_failclosed_test.exs:549` — fence 10 (restart hammer,
  relative-ratio duration fence)
- `test/affidavit_wasm_failclosed_test.exs:657` — fence 11 (supervised-restart
  kill-loop hammer)
- `test/affidavit_wasm_failclosed_test.exs:759` — fence 12 (start while running
  is typed already_started passthrough)

Whole-file spec (14 tests) is the sound shape — multi-spec file:line invocation
reproduces a `Store already started` double-boot face (documented in the prior
receipt).

## Command

    for i in $(seq 1 10); do
      MIX_BUILD_ROOT=_build-ft-fh2 mix test test/affidavit_wasm_failclosed_test.exs
    done

Run from `/Users/sac/smalt`. No edits, no git, no `_build` deletion.

## 10-run table

| run | exit | summary | wall |
|---|---|---|---|
| 1 | 0 | 14 tests, 0 failures | 7.9s |
| 2 | 0 | 14 tests, 0 failures | 10.5s |
| 3 | 0 | 14 tests, 0 failures | 9.1s |
| 4 | 0 | 14 tests, 0 failures | 8.3s |
| 5 | 0 | 14 tests, 0 failures | 7.6s |
| 6 | 0 | 14 tests, 0 failures | 6.8s |
| 7 | 0 | 14 tests, 0 failures | 7.3s |
| 8 | 0 | 14 tests, 0 failures | 7.7s |
| 9 | 0 | 14 tests, 0 failures | 8.0s |
| 10 | 0 | 14 tests, 0 failures | 9.0s |

Acceptance: 10/10 identical green — MET. Matches the prior 6eec145 baseline
(10/10 at 14 tests); no regression from the Bandit shutdown / atom_bridge
changes.

## Machine context (honest)

Shared machine, sibling lanes active (same conditions as the prior hammer
window). Build root `_build-ft-fh2` reused across all 10 runs.

## Falsifier / non-vacuity

A red run would flip this receipt to FAIL. The boot-face non-vacuity evidence
(multi-spec double-boot) is documented in `i29-fence-hammer.md`.
