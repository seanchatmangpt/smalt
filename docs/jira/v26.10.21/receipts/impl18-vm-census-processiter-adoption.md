# IMPL-18 — vm_zero_growth census adopted onto Smalt.ProcessIter.reduce (writer, OTP-29)

Context: solo

**Standing:** **PASS** (2/2 tests green on OTP 29.1.1, real booted app, real churn)

## Change

`test/internal/vm_zero_growth_test.exs` — `census/0` no longer calls
`:erlang.processes/0` (the whole-VM pid list materialization that IMPL-1
deliberately left). It now reduces over the whole-VM population with
`Smalt.ProcessIter.reduce/3` (OTP 29 `processes_iterator` BIFs), keeping the
census semantics identical: same process count, same monitor sum, same
ConnSup-subtree exclusion, monitor still counted once via the supervisor side.
The only per-visit state is the `{p_count, m_sum}` integer accumulator — no
per-visit heap allocation; the ETS/atom census terms are unchanged
(off-heap).

Diff (worktree == HEAD via coordinator checkpoint `4326bd6`, census body):

```elixir
{processes, monitors} =
  Smalt.ProcessIter.reduce({0, 0}, fn pid, {p_count, m_sum} ->
    m_sum =
      cond do
        MapSet.member?(conn_sup_children, pid) -> m_sum
        true ->
          case :erlang.process_info(pid, [:monitors, :monitored_by])
            :undefined -> m_sum
            info -> m_sum + length(Keyword.get(info, :monitors, []))
          end
      end

    {p_count + 1, m_sum}
  end)
```

(The file also drops the now-dead `pids = :erlang.processes()` binding and the
`length(pids)` processes count — `processes: processes` from the reduce.)

## Verification (Chicago)

```
export PATH="$HOME/.asdf/installs/erlang/29.1.1/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
export FAST_TEST_BUILD_ROOT=_build-impl18
scripts/fast_test.sh test/internal/vm_zero_growth_test.exs

Running ExUnit with seed: 173892, max_cases: 32
..
Finished in 0.2 seconds (0.00s async, 0.2s sync)
Result: 2 passed
[14:00:05] wall: 2s (build root: _build-impl18)
```

Toolchain: OTP 29.1.1 (erts 17.1) + Elixir 1.20.4-otp-29; mode pinned
`Smalt.ProcessIter.mode() == :iterator` by the probe assertion.

## Heap-delta before/after (honest numbers, min-of-5 paired rounds)

Scratch probe (fresh-process, pre-GC `total_heap_size` delta — heap does not
shrink before a GC, so the post-call read is the peak the traversal drove the
heap to; probe deleted after measurement, snapshot accidentally landed in
coordinator commit `e626924`, see disclosures):

Real booted smalt app VM, **1,492 live processes**, `mode=:iterator`, 5/5
deterministic rounds:

```
old (:erlang.processes/0 + Enum.reduce) total_heap deltas (words): [10802, 10802, 10802, 10802, 10802]
new (Smalt.ProcessIter.reduce)          total_heap deltas (words): [ 9178,  9178,  9178,  9178,  9178]
```

= **−1,624 words (−15.2%)** at the tier's live population. Scaling shape
(standalone OTP 29 VM, pre-GC total_heap delta, 100/1k/10k processes:
`old 0/2353/28457` vs `new 407/6568/21713` — crossover above ~2k processes,
−24% at 10k) confirms the iterator's cost is sublinear in population while
`processes/0`'s list is linear; the adoption win grows with VM population.

Observable notes (method honesty): `erlang:statistics(:garbage_collection)`
was tried first and rejected — it is **VM-global**, not process-local, so it
cannot isolate the traversal. Resident-process post-GC `heap_size` reads were
also rejected — a resident process's high-watermark heap absorbs the pid list
without growing (fake 0/0 ties, 5/5 rounds). The pre-GC fresh-process
`total_heap_size` read is the honest peak proxy; numbers are deterministic.

## Disclosures (same-checkout fan-out)

- **Compile-freeze observe-only**: first lane build hit a shared-lib compile
  error in `lib/smalt/json_compat.ex` (in-flight `finish_stream/3` /
  `native_sax?/0` streaming work, undefined at that moment). I did not touch
  the file; the owning lane landed both defs within ~4 minutes (mtime
  witnessed) and my build cleared. No unblock fix applied.
- **Probe-file intake**: my scratch probe
  (`test/internal/impl18_heap_probe_test.exs`) was snapshotted into the
  coordinator checkpoint `e626924` while still mid-edit; after measurement I
  removed it, which left a ` D` against HEAD. Restored byte-exact to HEAD
  (sha256 `0d6427fa...bc99` both sides). The coordinator should decide intake
  (keep as a heap-probe fixture or drop in a follow-up commit).
- No `git stash`; file baseline snapshot via `git show HEAD:path` only.

## Falsifiers

- A census-semantics regression would fail the two zero-delta tests — they
  pass (2/2).
- A traversal that allocates per-visit state would move the new-side heap
  delta with population; measured stable across 5 paired rounds.
