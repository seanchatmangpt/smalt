# IMPL-1 — AR-CORE-01 processes-iterator adoption, `Smalt.ProcessIter` seam (v26.10.21)

**Standing:** **ALIVE** (Chicago court 1/1 PASS on the green OTP-29 toolchain; adoption
seam landed; honest finding: zero `processes/0` call sites existed in `lib/smalt`)
Context: solo
Machine: Apple M3 Max / OTP 29.1.2 (erts-17.1.1) / Elixir 1.20.4-otp-29 / `MIX_BUILD_ROOT=_build-impl1`

## Artifacts

- `lib/smalt/process_iter.ex` (new) — `Smalt.ProcessIter`: heap-bounded whole-VM
  traversal via `:erlang.processes_iterator/0` + `:erlang.processes_next/1`
  (arbiter-specified API, confirmed empirically: `next/1 -> {pid, iterator} | :none`).
  `mode/0` reports `:iterator | :fallback_full_list` (pre-29 fallback is typed,
  never silent). Surface: `mode/0`, `iterator/0`, `next/1`, `reduce/3`, `count/1`,
  `caller_heap_words/0`.
- `test/internal/process_iterator_court.exs` (new) — spawns 200k real trivial
  processes, traverses via the iterator, visited-once census in ETS (off-heap so
  the court does not violate the bound it asserts), flunks on any duplicate pid,
  asserts iterator caller-heap delta < 100k words, and reads the `processes/0`
  baseline on the same live population for the both-numbers record.

## Adoption-scope finding (honest)

Repo-wide grep: **zero** `:erlang.processes/0` / `Process.list/0` call sites in
`lib/smalt`. Only hits: `test/internal/vm_zero_growth_test.exs:33` (whole-VM
census harness, test tier, deliberately untouched) and a mention in
`scripts/non_duplication_gate.py`. Nothing to replace; adoption landed as the
canonical seam so future call sites have a lawful path.

## Green output (court, real run)

```
$ MIX_BUILD_ROOT=_build-impl1 mix test test/internal/process_iterator_court.exs --trace
InternalTier.ProcessIteratorCourtTest [test/internal/process_iterator_court.exs]
  * test iterator traverses 200k processes, heap-bounded, each pid exactly once [L#47]
AR-CORE-01 heap deltas (words, GC'd reads): iterator=0 processes/0=514605 population=201492

  * test iterator traverses 200k processes, heap-bounded, each pid exactly once (228.6ms) [L#47]

Finished in 0.4 seconds (0.00s async, 0.4s sync)

Result: 1 passed
```

Iterator caller-heap delta **0 words** vs **514,605 words** for `processes/0`
(>512,000x reduction measured this run) on the identical 201,492-process
population; every pid visited exactly once (active dup-check would flunk).

## Cross-lane disclosure (compile-freeze SLA)

First compile under Elixir 1.20 failed on `lib/smalt/data_plane/file_share.ex`
(`int_in/3` guard macro undefined at use sites) — pre-existing TOOLUP-lane
in-flight break, not session-introduced. I began a `defguardp` unblock; IMPL-4
landed theirs (line 6) concurrently and a third copy appeared near line 388. I
removed my duplicate — my net line contribution to that file is zero. Residual:
the file still carries two `defguardp int_in` definitions (lines 6 and 388)
owned by those lanes; compile currently succeeds, dedupe at integration.
`mix compile` is green under OTP 29 (pre-existing type warnings only).

## Residuals

- Gate run = single-file court + compile under OTP 29, not the full suite.
- `vm_zero_growth_test.exs` still uses `processes/0` (census semantics, test tier).
