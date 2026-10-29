# POWL-9 — POWL2 execution kernel (`Smalt.POWL2.Executor`)

Date: 2026-10-21. Lane: powl9 (writer). Repo: /Users/sac/smalt.
**Standing:** **PARTIAL_ALIVE** — kernel witnessed by 7/7 Chicago tests on the
lane build root `_build-powl9`; wave deps (POWL-4/6/7) were landing and
rolling back around this lane while it worked (see Environment).

## Files

- `lib/smalt/powl2/executor.ex` (md5 239f1c4291348f72dc0df7bdb609a32d):
  pure topology engine. Ops injected per node as fun/1 or {m,f,a} on the
  node's `:op` field — no domain ops in the kernel. PO frontier
  concurrency via Task.async/await under a 30s deadline. ChoiceGraph
  guard pick: exact `last_outcome` match wins, `:always`/unguarded
  fallback; guards carried in an optional `:guards` map on the ChoiceGraph
  node so edges stay plain {from, to} pairs (the reticle's SESE checks
  crash on guarded 3-tuple edges — found live, tests conform). Receipts to
  `{:powl2_receipt, id}`, refusals to `{:powl2_refusal, id}` in `dets_ref`.
  Messages: `{:orchestration_completed, id, ctx, receipt}`,
  `{:orchestration_refused, id, reason}`, `{:orchestration_failed, id, outcome}`.
  Struct dispatch by `__struct__` name (`Smalt.POWL2.Reticle.AST.*`) with
  no compile-time struct expansion, so the kernel survives wave rollback;
  Gate 1 re-admission runs through `Smalt.POWL2.Reticle` only when loaded
  (overridable via 6th arg for courts).
- `test/internal/powl2_executor_test.exs` (md5 ec3545ca7043954723814fc080912f73):
  7 Chicago tests; real DETS tables, real Tasks, real message passing;
  zero `Process.sleep` — the PO concurrency witness is a barrier protocol
  (both frontier ops must start before either is released; a serial
  frontier dead-locks into the deadline and fails).

## Command output (actual, both runs)

```
$ MIX_BUILD_ROOT=_build-powl9 mix test test/internal/powl2_executor_test.exs
Running ExUnit with seed: 87831, max_cases: 32
.......
Finished in 0.2 seconds (0.00s async, 0.2s sync)
7 tests, 0 failures
```

Second run (flake check): `7 tests, 0 failures` (seed 87931-class rerun,
same 7 dots). `mix compile --force`: zero warnings or errors attributable
to `executor.ex` (grep count 0). Sleep-gate scan: 0 `Process.sleep` in
both owned files.

## Coverage

1. Linear 3-step workflow: completes, `receipt.phi_lease_final == 3`,
   steps `[:a, :b, :c]` chronological, ctx merge `ctx.c == 3`, receipt
   re-read from real DETS.
2. ChoiceGraph takes the `:ok` branch, `err_branch` never executes
   (its op raises if ever run), `phi_lease_final == 2`.
3. ChoiceGraph `:always` fallback fires when `last_outcome: :weird`.
4. PO frontier runs concurrently (barrier witness) and merges: ctx has
   x/y/merged, step order is wave1 {x,y} in either order, then merge
   node; `phi_lease_final == 3`.
5. Non-admitted model refused when a reticle is available (test-local
   refusing reticle module injected via the 6th arg): typed
   `{:shacl_violation, "contraband"}` refusal + `{:powl2_refusal, ...}`
   DETS row + `{:orchestration_refused, ...}` message.
6. `{:error, :not_admitted}` verdict refused without reticle, refusal row
   in DETS.
7. Op failure fails the run, still records the error receipt, sends
   `{:orchestration_failed, ...}`.

## Environment / collisions (disclosure)

- POWL-4/6/7 deps landed LIVE during this lane (bounded 20-min poll
  consumed). The AST landed as `Smalt.POWL2.Reticle.AST.*` (reconciled
  shape in reticle.ex); this lane re-pointed dispatch to it and conformed
  choice edges to plain {from,to} pairs after observing the reticle's
  SESE check crash on 3-tuple edges.
- Compile-freeze: the shared tree broke three times mid-run from sibling
  lanes (change_feed.ex `notify_watermark/2`, decomposition.ex
  `reach/1`, projection.ex delimiter); each was fixed by its owner within
  the SLA — no cross-lane edits by this lane.
- The entire `lib/smalt/powl2/` tree (including this lane's executor.ex)
  was deleted twice by wave rollback around 11:58 while this lane was
  verifying; executor.ex was re-authored and re-verified to the current
  md5. If the re-landed wave's reticle keeps the same module/struct names
  and {from,to} edges, the kernel needs no changes; a struct-shape change
  would require re-pointing the three `__struct__` dispatch clauses.
- Known interface note for the coordinator: the reticle's
  `Transition` defstruct carries only `[:id, :label]` — no `:op` field —
  while the dispatch contract here injects ops on the node. The kernel
  reads `:op` via `Map.get`, so real structs without `:op` will refuse
  with `:no_op`; ops must either be added to the landed struct or supplied
  via the `%{model: inner}` wrapper/`Map.get`-compatible maps.

## Falsifiers (open)

- If PO frontier execution were serial, the barrier test dead-locks and
  fails — currently holds.
- If the reticle admits a model whose `start` is not a child, or the
  executor executes a guarded branch without a matching `last_outcome`,
  tests 2/3/5 fail — currently hold.
