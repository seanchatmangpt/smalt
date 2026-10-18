# i22 — fuzz_test.exs:561 atom-flood measurement fence (attempt 4, leg 1)

- **Date**: 2026-10-18
- **Lane**: fix lane, `MIX_BUILD_ROOT=_build-ft-r10`, repo `/Users/sac/smalt`
- **Standing**: NOT-REPRODUCIBLE (stand-down; no fix applied)
- **Subject**: `test/amqp/fuzz_test.exs:561` — "5000 unique long symbol source/target keys mint no new atoms"

## Reading of the assertion

The test is **not** a global-constant atom assertion. Structure (lines 560-655):

1. Structural primary proof: decodes a hand-built attach whose source map
   carries 5000 unique wire keys; asserts every decoded key is a binary
   (or the defaulted `:filter` atom) — the real regression fence for the
   retired `String.to_atom/1` fallback in `safe_atom/1`. This part cannot
   flake on concurrent atom allocation.
2. Secondary measurement fence (lines 612-620): three tight
   `:erlang.system_info(:atom_count)` delta windows around re-decodes,
   pass iff `Enum.any?(windows, &(&1 <= 10))`. This is the only
   perturbation-sensitive part: concurrent tests' lazy init can mint
   >10 atoms in every window simultaneously. Atoms never GC, so any
   concurrent minting lands in the measurement.

So the failure class is the secondary fence only, and the prescribed fix
(bounded concurrent-allocation slack with measured jitter) applies there.

## Repro attempt (as directed: paired with test/corpus_test.exs, 3x)

Command (each run):

```
MIX_BUILD_ROOT=_build-ft-r10 mix test test/amqp/fuzz_test.exs test/corpus_test.exs --include atom_flood
```

Actual output (tails):

```
=== RUN 1 === Finished in 19.1 seconds (13.9s async, 5.1s sync) — 60 tests, 0 failures
=== RUN 2 === Finished in 17.7 seconds (13.4s async, 5.1s sync) — 60 tests, 0 failures
=== RUN 3 === Finished in 20.4 seconds (15.2s sync)        — 60 tests, 0 failures
```

3/3 paired runs green. `:atom_flood` is not in the default-exclude list
(`test/test_helper.exs` excludes only `:amqp_wire`), so the test genuinely
executed in every run.

## Decision

Stand down **NOT-REPRODUCIBLE**. Per lane instructions: apply a fix only
with a cited measured distribution of the atom-count jitter; the paired
repro never produced a failure, so there is no measured failing
distribution to calibrate a slack bound against. No edit was made to
`test/amqp/fuzz_test.exs`.

Note for the next attempt: if the failure reappears under full-suite
concurrency (heavier async pressure than the 2-file pair), the fix shape
is per instructions — assert the DELTA over the test's own keys only
(the 5000 exact keys are provably absent from the table pre-mint and the
structural asserts already pin them to binaries), or snapshot
`atom_count` with a bounded slack derived from a measured concurrent
distribution, never a global constant.
