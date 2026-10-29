# BK-FONDV2 — fond chain composition verification (4 lanes, 2 files, current HEAD)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-FONDV2 (read-only verify), canonical checkout /Users/sac/smalt,
  MIX_BUILD_ROOT=_build-bkfondv2 (left for coordinator `just lane-clean`)
- **Composes**:
  docs/jira/v26.10.22/receipts/bkfondskep-runner-audit.md (F1-A + F6-A/B
  findings),
  docs/jira/v26.10.22/receipts/bkfondsd-repairs.md (F1-A + F6-B),
  docs/jira/v26.10.22/receipts/bkdupid-dedup-fix.md (dup-id dedup),
  docs/jira/v26.10.22/receipts/bkf6r-receive-bound.md (F6-A bounded receive),
  docs/jira/v26.10.22/receipts/bkfondv-f1a-verify.md (14/15 → BK-FONDV-1),
  docs/jira/v26.10.22/receipts/bkfondw-f1a-closure.md (15/15 closure).

## Verdict

ALIVE. The four-lane composition (F1-A mirror repair + BK-DUPID dedup +
BK-F6R bounded receive + BK-FONDSD slice-poll fence — all landing in the
same two files) holds on current HEAD, verified fresh on an independent
build root. No merge-conflict or composition regression.

## (1) Fond court fresh (incl. skeptic): 31/31

```
$ MIX_BUILD_ROOT=_build-bkfondv2 mix test test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
Result: 31 passed
```
exit=0. Run started at machine load ~22 (concurrent lanes compiling);
no flake.

## (2) 15-shape T1 probe (independent reconstruction): 15/15 AGREE

Fresh probe (/tmp/bkfondv2_probe.exs — fresh literals, fresh executor
simulation: real `:smalt_fond_plan.assert_acyclic/1` vs real
`:next_ready/2` with an id-keyed done set reduced to fixpoint, fuel =
n+5), `mix run --no-start`, exit 0:

```
linear: planner=:ok executor=:executable => AGREE_EXEC
diamond: planner=:ok executor=:executable => AGREE_EXEC
fork: planner=:ok executor=:executable => AGREE_EXEC
join: planner=:ok executor=:executable => AGREE_EXEC
mixed_provides: planner=:ok executor=:executable => AGREE_EXEC
unprovided: planner={:refused, {:unprovided_need, [a: :never_provided]}} executor={:not_executable, [:a]} => AGREE_REFUSED
cycle: planner={:refused, {:cyclic_plan, [:a, :b]}} executor={:not_executable, [:a, :b]} => AGREE_REFUSED
self_need: planner={:refused, {:cyclic_plan, [:s]}} executor={:not_executable, [:s]} => AGREE_REFUSED
dup_provider: planner=:ok executor=:executable => AGREE_EXEC
dup_provider_min: planner=:ok executor=:executable => AGREE_EXEC
empty: planner=:ok executor=:executable => AGREE_EXEC
done_id_only: planner=:ok executor=:executable => AGREE_EXEC
dup_ids: planner=:ok executor=:executable => AGREE_EXEC
diamond_mixed: planner={:refused, {:unprovided_need, [m: :rxx]}} executor={:not_executable, [:m]} => AGREE_REFUSED
late_provider: planner=:ok executor=:executable => AGREE_EXEC
T1: 15/15 AGREE; DIVERGE count=0
```

Both refusal directions intact via real `run/1` (real gen_statem, no
mocks):

```
refusal witness => {:crash, {{:unprovided_need, [b: :never_provided]}, [smalt_fond_plan:assert_acyclic/1, line 81, ...]}}
refusal midchain_ghost => {:crash, {{:unprovided_need, [b: :ghost]}, [assert_acyclic/1, line 81, ...]}}
refusal cycle_real => {:crash, {{:cyclic_plan, [:a, :b]}, [smalt_fond_plan:kahn/5, line 107, ...]}}
```

## (3) F6-A: hang-shape probe returns typed, 101 ms (< 5 s)

`contingency = fn _ -> :timer.sleep(:infinity) end`, `timeout: 100`,
real `run/1`:

```
F6-A hang-shape result: {:crash, {fond_receive_timeout, %{timeout_ms: 100, plan: ..., note: ...}}}
elapsed_ms=101
TYPED_OK
```

## (4) F6-B: S3 leg green under the slice-poll form

```
$ MIX_BUILD_ROOT=_build-bkfondv2 mix test test/pipeline/fond_powl_runner_court_test.exs:237 --include fondrunner_skeptic
Result: 1 passed, 30 excluded
```
exit=0. (The slice-poll `recv_until_ok/2` replaces the fixed 10 s fence;
S3 also passed inside the full 31/31 court run in leg 1.)

## (5) expl10r suite fresh

```
$ MIX_BUILD_ROOT=_build-bkfondv2 mix test test/internal/expl10r_court_test.exs
Result: 15 passed
```
exit=0.

## Disclosures

- **Probe-side iteration 1 misclassified 5 shapes** (my probe's
  classification, not the code): (a) `rescue` grabbed Erlang errors as
  `%ErlangError{}` before the `catch :error` arm saw them →
  `{:exn, ...}` read as non-refusal; (b) the dup_ids executor leg
  compared `map_size(done) == length(sim)` where `length(sim)` counts
  the duplicate — the executor's done-set is id-keyed and collapses
  dups, so completion must be measured against the DEDUPED id list.
  After correcting both probe defects: 15/15 AGREE, zero DIVERGE. The
  first-run output is preserved at /tmp/bkfondv2_probe.log (before the
  fix it read "10/15"; the second run overwrote it — the misclassified
  lines are quoted in the lane transcript, not independently preserved).
- Machine was never quiet (load 17-24 throughout; `just quiet-check`
  not satisfiable) — Context: solo, load disclosed. All runs passed
  first try anyway.
- Two unrelated dirty test files on the tree
  (test/integration/namespace_put_test.exs,
  test/internal/ets_auto_court_test.exs) are other lanes' in-flight
  edits; not touched, not compiled into these legs' failure sets (all
  legs exit 0).

## Falsifiers (standing)

- Any DIVERGE line in the 15-shape probe re-opens F1-A/BK-FONDV-1.
- `dup_ids` / `join` flipping away from `:executable`, or any of the
  three refusal legs returning `{:ok, _}` / sealing, re-opens the
  accept-direction question.
- A hang-shape `run/1` not returning typed `{:crash,
  {fond_receive_timeout, _}}` within 5 s re-opens F6-A; default
  (no-:timeout) legality legs regressing re-opens BK-F6R.
- S3 failing twice consecutively under the slice-poll form re-opens
  F6-B.
- The 31 fond-court legs and 15 expl10r legs are regression guards.
