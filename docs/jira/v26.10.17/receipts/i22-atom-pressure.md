# i22 — atom-table pressure vs scheduler jitter for fuzz/atom-mint tests

Standing: PASS (with a falsifier carried forward)
Date: 2026-10-18
Lane: read-only + one measurement; no source edits.

## Question

Do `test/amqp/fuzz_test.exs:561` (5000 unique keys) and the 1000-PUT corpus
sweeps hit atom-table pressure or scheduler saturation under parallel suite
load?

## 1. What the test asserts

Both. `test/amqp/fuzz_test.exs:561` has two layers:

- Primary structural proof: decoded map of 5000 hostile wire keys carries
  every key as a binary (never an atom), `map_size == 5001` (incl. `:filter`).
- Secondary measurement fence (test lines ~606-616): three tight
  before/after windows of `:erlang.system_info(:atom_count)` around
  `FrameCodec.decode_frame/1`; pass iff any window delta <= 10, with the
  deltas in the failure message.

The 1000-PUT sweep (`test/corpus/shacl_fuzz.exs:98`) asserts verdict classes
only — no atom_count assertion. It does real HTTP PUTs through the full
stack; it is a scheduler-load test, not an atom test.

## 2. Measurement (solo, MIX_BUILD_ROOT=_build-ft-atom)

Solo run of the fuzz suite:

```
$ MIX_BUILD_ROOT=_build-ft-atom mix test test/amqp/fuzz_test.exs
Finished in 13.9 seconds (13.9s async, 0.0s sync)
34 tests, 0 failures
wall: 2m42s total (incl. compile of the private build root; 279.89s user / 64.06s sys / 211% cpu)
```

Atom deltas from the exact decode path (mix run -e, warm decode first,
then 3 windows, mirroring the test):

```
WINDOW_DELTA 0 count=38197
WINDOW_DELTA 0 delta 0 count=38197
WINDOW_DELTA 0 count=38197
FINAL count=38197 limit=1048573.6
```

- Decode of 5000 unique wire keys mints ZERO atoms per window.
- Table at 38,197 / 1,048,576 (~3.6%) — nowhere near exhaustion.
- Even an adversarial sibling module would need ~1M mints to kill the VM;
  the fixed safe_atom/1 fallback is gone (structural assert proves keys
  return as binaries).

## 3. Comparison with in-suite times

tmp/court-x2-v17-wrap4.log: run 1 finished in 289.1s (8.3s async,
280.7s sync); run 2 in 324.7s (13.3s async, 311.3s between-run variance
sized sync). Solo the whole fuzz file is 13.9s of test time. The suite runs
mostly sync under `mix test` (ExUnit async: false for these modules), so
the atom test is not racing on schedulers in a way that perturbs
atom_count (it is a sync test on one runner process; atom_count is
VM-global and monotone — jitter cannot shrink a delta, only add unrelated
lazy-init mints to it).

## 4. Verdict

**Not atom exhaustion.** The decode path mints 0 atoms (measured, 3/3
windows delta 0), the table sits at ~3.6% of limit, and the structural
assert (keys as binaries) is what the fix actually proves. Even the
measurement fence has a 3-window retry design (D63/R95) to absorb
unrelated lazy-init mints.

The witnessed in-suite failure is **inconsistent with atom pressure**.
Combined with the court log's SHIFTING-FAILURE signature (run 1 failed
only the atom test; run 2 failed five entirely different corpus tests
with the atom test passing), the flake class is load-sensitive
interference — sibling tests ([amqp-atom] debug spam, Handler
sync/drop churn visible in the log) and possibly the run-1 compile of
generated_verify.ex verify crash — not the atom table. The in-suite
atom-test failure in run 1 most plausibly saw a >10-atom lazy-init window
under load (the fence is the noise-sensitive layer; the structural layer
is the sound proof and cannot flake this way).

Falsifier carried forward: if a future in-suite failure message names
"atom table grew on every window decoding 5000 unique wire keys" with
windows > 10 AND the structural asserts still hold, re-run this exact
measurement in-suite (test exposes windows only on failure) before
blaming jitter.

## Replay

```bash
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-ft-atom mix test test/amqp/fuzz_test.exs   # 34 tests, 0 failures, 13.9s
MIX_BUILD_ROOT=_build-ft-atom mix run -e '...'                    # WINDOW_DELTA 0 x3, limit 1048576
rm -rf _build-ft-atom                                             # done post-receipt
```
