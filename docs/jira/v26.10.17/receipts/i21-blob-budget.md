# i21 — blob pagination perf budget: 110 -> 180 ms (load-robust, revert-fenced)

Standing: ALIVE
Context: solo (single test x3 quiet + 2-yes-hog load leg)
Lane lease: `test/data_plane/blob_hardening_test.exs` pagination perf contract (~:1518-1556) only.
Date: 2026-10-18. MIX_BUILD_ROOT=_build-ft-bpag. No git.

## Face

`pagination perf contract violated: 119 ms > 110 ms budget (per-rep runs [138, 119, 170])` under
load; passed quiet.

## Investigation (measured, not assumed)

- Quiet re-measure at 110 budget: min-of-3 read 128 ms on a quiet run — the OLD budget flaked
  even without load (`pagination perf contract violated: 128 ms > 110 ms budget`, exit 1, witnessed
  in-session).
- Quiet full-chain keys-only: min 64 ms (runs [75,66,64]); under 2 yes-hogs min 67 ms
  (runs [105,77,67]). Anchors the quiet median ~62-67.
- Revert-class (full-value materialization) estimate: ~3.3x keys-only -> ~205 ms quiet, scaling
  to ~3.3 x 170 ≈ 560 ms loaded. Proxies measured this session: page-local get-per-name proxy
  showed no separation (ETS gets are cheap); whole-keyspace materialization proxy measured 102 ms
  vs 67 keys-only — direction confirmed, magnitude from the historical 3.3x figure in the
  original court comment.

## Change

`@perf_budget_ms 110 -> 180`, min-of-3 reps -> min-of-5 reps, regression-detection math moved
into the block comment (cites 128 quiet flake, 138/119/170 loaded, 3.3x revert class, and why
300 ms would NOT fence: it exceeds the ~205 ms quiet revert estimate).

### Regression-detection math (stated in the comment)

- 180 = ~2.8x quiet median 64; headroom over worst quiet flake 128 = 1.4x; over worst loaded
  rep 170 = 1.06x.
- Revert trips: quiet revert ~205 > 180; loaded revert ~560 >> 180. 300 ms was rejected because
  it exceeds the ~205 ms quiet revert estimate and would admit the regression class it exists to
  fence.
- min-of-5 suppresses the scheduler-tail flake class (a 128 ms min-of-3 means 3 consecutive
  reps > 110; min-of-5 requires 5 consecutive reps > 180 = 2.8x median to false-fail).

## Verification (real output)

MIX_BUILD_ROOT=_build-ft-bpag `mix test test/data_plane/blob_hardening_test.exs:1541`:

- quiet x3: `1 test, 0 failures (115 excluded)` x3
- under 2 yes-hogs: `1 test, 0 failures (115 excluded)`
- Non-vacuity court (budget shimmed to 60 ms, marker SHIM-COURT intent): FAILED as required —
  `pagination perf contract violated: 65 ms > 60 ms budget`, `1 test, 1 failure (115 excluded)`;
  file restored byte-exact (edited-state sha256 `e600b6ea…f49d4` re-verified after restore).

## Falsifier

A quiet min-of-5 min > 180 ms on a healthy tree, or a materialization revert passing at 180.
