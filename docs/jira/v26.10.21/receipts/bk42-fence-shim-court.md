# BK-42 — Popcorn ratio-fence shim court (non-vacuity proof)

**Standing**: ALIVE — the BK-23 popcorn ratio fence is now non-vacuity-proven:
the court injects a marked mutation that breaks the paired-baseline wiring and
watches the fence REFUSE it (`KV-RATIO-FAIL`, exit 2), with byte-exact restore.
Closes the BK-23 named residual ("Ratio fence NOT non-vacuity-proven").
**Context: solo**
**Date**: 2026-10-21

## Subject

- Fence: min-of-3 rounds of (wire p99 / paired echo-baseline p99) < 250 +
  100ms absolute backstop — `popcorn_demo/test/empirical_flag_latency_test.exs`
  (sha256 `590db3a45b90207ed4ec0e0339d5cfa3b618b072cd5c04daf823d3aec84a7810`)
  and `popcorn_demo/test/empirical_kv_latency_test.exs`
  (sha256 `2bc354f48346cd3645d9aca13a1a95fc8aea4403abd3882a6ef93393b6505782`).
- Court: `scripts/shim_court/popcorn_ratio_fence_court.sh` (new, this lane).
- Build root `MIX_BUILD_ROOT=_build-bk42`, run from `popcorn_demo/`,
  asdf-pinned elixir 1.20.4-otp-29 / erlang 29.1.2 (court script prepends
  `$(dirname $(asdf which mix))` to PATH — plain `mix` resolved 1.19.5 and
  refused the project).

## Shim

Injected in-place into `empirical_kv_latency_test.exs` only (snapshot kept in
`/tmp`, restore fail-closed on sha256):

```elixir
# SHIM-COURT BK-42: broken baseline wiring — constant 1us baseline
defp baseline_p99 do 1 end
defp baseline_p99_shimmed_original do   # original body continues below
```

The paired baseline is the fence's load-normalization term; a constant 1µs
baseline is exactly the rejected-ETS failure mode BK-23 documented (baseline
does not inflate under load → ratio does not normalize → every real load spike
breaches the fence). A fence that still passes with its baseline wiring broken
is vacuous.

## 5-phase transcript (final passing run, 21:23 local)

```
=== BASELINE ===
kv test sha256: 2bc354f48346cd3645d9aca13a1a95fc8aea4403abd3882a6ef93393b6505782
=== BEFORE (unshimmed fence must be green) ===
Finished in 2.0 seconds (0.00s async, 2.0s sync)
Result: 6 passed
BEFORE attempt 1 exit: 0
=== SHIM (SHIM-COURT: break paired-baseline wiring) ===
1                                       <- grep -c "SHIM-COURT" (marker present)
shimmed kv test sha256: 107d598b0e2eb4ea73fc31f4ba2a982f732da6d53d91abff95f72f3d0bd7bdd0
=== AFTER (shimmed fence must REFUSE: exit nonzero) ===
[E4KV get latency] ... (real wire run against live substrate)
  round 1: p50=1046us  p99=317068us  baseline_p99=1us  ratio=317068.0
  round 2: p50=939us   p99=1422us    baseline_p99=1us  ratio=1422.0
  round 3: p50=1074us  p99=211102us  baseline_p99=1us  ratio=211102.0
  1) test KV secret GET latency contract: ... (PopcornDemo.EmpiricalKVLatencyTest)
     KV-RATIO-FAIL: best-round wire/echo-baseline p99 ratio=1422.0 >= 250.0 fence
     (wire p99=1422us, baseline p99=1us — ...)
Result: 2/3 passed
Failed: 1 test
AFTER exit: 2
=== RESTORE ===
[RESTORE] sha256 2bc354f48346cd3645d9aca13a1a95fc8aea4403abd3882a6ef93393b6505782 (byte-exact)
COURT PASS: fence REFUSED the mutation (exit 2), restore byte-exact
COURT-EXIT: 0
```

Full logs: `tmp/bk42-before.log`, `tmp/bk42-after.log` (scratch, gitignored).
Restore re-verified after the run: both latency test files git-clean
(`git status --short popcorn_demo/test/` → empty), shas match the values above.

The AFTER refusal is the non-vacuity proof: with baseline wiring broken, the
fence fires on real wire measurements (`KV-RATIO-FAIL` at the `@ratio_fence`
assert, `empirical_kv_latency_test.exs:140`), not on an artificial failure.

## Development runs (pre-final, same lane — disclosed)

- Run 1: BEFORE failed with `(Mix) You're trying to run :popcorn_demo on
  Elixir v1.19.5` — system mix vs asdf pin; fixed by PATH prepend in the
  court script. Not a fence result.
- Run 2: BEFORE 0 tests / 6 skipped — substrate was down (concurrent-lane
  transition); skip is loud, court refused to count it as green.
- Run 3: AFTER exit 1 from an unrelated in-flight compile break in
  `lib/popcorn_demo/live_certs.ex` (another lane mid-edit; compile-freeze
  class). Court correctly did not accept it; re-run once the lane's file
  compiled (`mix compile` exit 0 confirmed first).
- Runs 4–5: BEFORE 5/6 — real load-face flakes under fleet load (load avg
  110–147 vs 16 cores; best-round ratios 1376/991 with the echo baseline
  stuck at ~150–290µs). Court refused to proceed. This is the documented
  BK-23 flake class at heavier load than calibration witnessed.
- Harness evolved accordingly: BEFORE retries up to 10 attempts, 60s apart
  (BK-23/r240 warm-run-2 discipline); after 10 failures it exits 3 — a loud
  skip, never a fake pass. Final run went green on attempt 1.

## Findings

- **Load-sensitivity finding (new, unfixed, owned by BK-23's calibration
  note)**: under extreme fleet load (load1 ~110–147 on 16 cores), all 3
  min-of-3 rounds can spike simultaneously while the echo baseline stays
  ~200µs — the ratio blows past 250 and the fence fails BEFORE even though
  the stack is innocent. BK-23's calibration witnessed baseline inflation
  (148–2446µs) that this heavier load class does not produce. The fence is
  honest (it refuses) but its best-round min-of-3 does not fully normalize
  machine-level saturation. Named residual for the fence owner; not shimmable
  away here.
- The `@substrate_skip` tag means the pair silently skips 6/6 when the
  substrate is down — exit 0. Loud in stderr but green to CI. Consistent with
  the repo's exit-code contract for harness-skip (exit 3 at harness level),
  but plain `mix test` reads as a pass. Observation only; not changed.

## Receipt

- Files changed (uncommitted, per dispatch): this receipt +
  `scripts/shim_court/popcorn_ratio_fence_court.sh` (new court). Both
  `popcorn_demo/test/empirical_*_latency_test.exs` files untouched
  (byte-exact restore witnessed above).
- Commands: court run exit 0 (final), `mix compile` exit 0 (pre-flight after
  the live_certs lane edit), `bash -n` syntax check, sha256 before/after.
- Falsifier status: BK-23 residual "no shim court shows the new fence
  refusing a mutated (inflated) measurement" → REFUTED by this court (the
  fence refused). Standing of the fence pair: ALIVE.
