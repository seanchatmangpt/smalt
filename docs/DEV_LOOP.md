# Dev Inner Loop

How to iterate on smalt without paying full-suite cost on every save.
Numbers measured 2026-10-14 on this checkout (Elixir 1.19.5 / OTP 28, warm shared `_build`).

## Scripts

- `scripts/fast_test.sh <test_file[:line]> [--watch] [--] [extra mix test args]`
- `scripts/dev_watch.sh [--once]`

## Timing receipts (real runs, 2026-10-14)

| surface | wall | result |
|---|---|---|
| full `mix test` (3 runs) | 8.0s / 8.0s / 7.0s | 1 doctest, 791 tests, 30-32 failures (19 excluded) — failures pre-existing, not introduced by this lane |
| `fast_test` first run on a new target file | 51-62s | one-time cold compile of the isolated build root |
| `fast_test` warm single file | 1-2s | 37 tests, 0 failures |
| `fast_test file:line` (warm) | 1-2s | 1 test, 0 failures (36 excluded) |
| graphlaw subset, `dev_watch.sh --once` | <1s test time | 59 tests, 1 failure — pre-existing ETS failure in `SmaltServicesTest` "Confidential Ledger Merkle Tree..." (`test/smalt_services_test.exs:231`) |

The one-time 50-60s is `MIX_BUILD_ROOT=_build-ft-<hash-of-file>` compiling deps+app from
scratch. It is a per-target one-time cost; every later run on the same target is 1-2s.
Trade-off: per-invocation build-root isolation buys parallel-invocation safety (two
`fast_test` invocations ran concurrently on different targets with no `_build` race,
both green) at the price of a cold compile per target file. If that cold cost is
unacceptable, set `FAST_TEST_BUILD_ROOT=_build-ft-shared` to share one warm isolated
root across targets, or `_build` to share the main root (accepting the race).

Env knobs: `FAST_TEST_BUILD_ROOT`, `DEV_WATCH_BUILD_ROOT`.

## Recommended loop

1. **Iterating on one test**: `scripts/fast_test.sh test/foo_test.exs:42 --watch`.
   Re-runs the focused test whenever `lib/**/*.ex` or the test file changes (1s poll,
   clear screen + timestamp, ~1-2s per warm run). First run may pay the ~1min cold
   build-root compile.
2. **Subsystem sweeps**: `scripts/dev_watch.sh` watches `lib/smalt/graphlaw/**` and re-runs
   the graphlaw suites (`test/smalt_graphlaw_validator_test.exs`,
   `test/smalt_services_test.exs`, `test/arm_error_corpus_test.exs` — 59 tests, <1s).
   **Generalizing**: copy the script, set `WATCH_PATHS=(lib/smalt/<subsystem>)` and
   `SUITES=(test/<subsystem>_test.exs ...)`; the mtime-snapshot/poll/re-run pattern is
   identical to `fast_test --watch`, just over multiple paths and suites. `--once` runs
   the subset a single time (used for all measurements above).
3. **Before push**: full `mix test` (7-8s here — cheap enough to run every time you
   think you're done, not just before push).
4. **Pre-PR**: `just court` (doctor + test-offline + test-wire + test-sdk-smoke +
   tf-plan-smoke + bench-check, per `Justfile:149`).

## Elixir 1.19 focus patterns

`mix test test/foo_test.exs:42` runs the single test whose `test` block starts at line 42
(works with `fast_test.sh` since the arg is passed straight through). Note `mix test
file:line` reports excluded siblings as `(N excluded)` — that is the line filter, not a
tag skip. `--only tag:value` / `--exclude` compose with file args for tier focus; the
default-excluded tiers are named in `test/test_helper.exs` (re-enable per run with
`--include <tag>`). Because the full suite is only ~8s, prefer full `mix test` over
`--only` gymnastics unless a single tier needs a cold build.

## Known state (pre-existing, observed during measurement)

- Full suite: 30-32 failures per run (count varies run to run) — pre-existing on this
  checkout; not touched by this lane.
- `test/smalt_services_test.exs:231` ETS-table failure also fires in the graphlaw subset.
- During measurement a compile-abort in `test/error_codes_doc_test.exs` (invalid syntax
  `test "..." well_formed: true do`) blocked the full suite; it was fixed on disk by
  another lane mid-measurement (compile-freeze SLA) and the 3x baseline above was taken
  after that fix. This lane made no edits outside its owned files.
