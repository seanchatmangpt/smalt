# Receipt — B0: LRO one-writer convergence (Notifier + await)

- **Window**: v26.10.18
- **Lane**: B0 (solo context)
- **Standing**: ALIVE (lane surface) — see Full-suite caveat
- **Spec**: `docs/jira/v26.10.18/rewrite-drafts/lib-redesign-wasm-lro.md` Part 2
- **Build isolation**: `MIX_BUILD_ROOT=_build-ft-ln` (lane-cleaned at integration)
- **Landed as**: coordinator checkpoint `21f58b0` contains the final B0 state
  (lib/smalt/arm_gateway/lro.ex, lro_notifier.ex, lro_sweeper.ex,
  application.ex child, test/lro_test.exs NotifierTest, this receipt)

## What landed

New `Smalt.ArmGateway.LRO.Notifier` GenServer (signal hub, op_id → monitored
waiters) + `LRO.await/2`/`await/3`; sweeper is the single terminal writer
(persists via the PUBLIC shared `evaluate/2`/`fail_closed/2` and publishes
terminals through the Notifier via explicit cast); the poll path
(`LRO.get_op/1`) is a reader that ROUTES its persistence through the writer
via synchronous `{:flip_due, key}` / `{:fail_closed, key, record}` requests
(disclosed: read path triggers the writer synchronously rather than
persisting itself — this is what keeps fence 10b/10d and the M37/lens-6/7
raw-read persistence fences GREEN unmodified, and it is strictly tighter
than the spec's "bounded staleness ≤ sweep interval" because the writer is
routed at poll time, not swept time).

Disclosed exceptions to strict single-writer ownership (pre-existing, named
in the spec):
- `Sweeper.flip_pass/0` remains PUBLIC and runs `evaluate/fail_closed` in
  the caller's process when invoked directly (`lib/smalt/enclave/state.ex:124`,
  enclave lifecycle reclamation) — pre-existing seam, unchanged.
- `flip_pass`'s malformed clause publishes to the Notifier from the caller
  process when flip_pass is invoked directly (same pre-existing seam).

## Fences

- Existing fence 10d ("sweep racing a wire poll converges to one persisted
  terminal, byte-identical body", `test/lro_test.exs`) — GREEN, UNMODIFIED.
- New fences (appended module `Smalt.ArmGateway.LRO.NotifierTest`):
  - B0-1 signal wake with zero polls/zero sweeps (due-check timer → writer
    cast → publish → waiter wakes; raw-read persistence + endTime identity
    between signal body and store body).
  - B0-2 typed timeout (`await(id, 0)` → `{:error, :timeout}`), no raise, no wedge.
  - B0-3 notifier-down face: kill Notifier mid-await → typed fail-safe
    convergence via bounded store polling (never a raise, never a wedge),
    store converges; supervision repairs the hub.
  - B0-4 subscription-scoped deny-by-default awaiter registration: foreign
    await refused `:error` immediately (<100ms, no waiter), owner await
    converges, unknown id `:error`.

## Real gate output

```
$ MIX_BUILD_ROOT=_build-ft-ln mix test test/lro_test.exs
Finished in 3.3 seconds (0.00s async, 3.3s sync)
37 tests, 0 failures
```

```
$ MIX_BUILD_ROOT=_build-ft-ln mix test test/enclave_state_test.exs test/smalt_ets_baseline_identity_test.exs test/smalt_ets_composite_identity_test.exs test/arm_error_corpus_test.exs
Finished in 3.5 seconds (0.00s async, 3.5s sync)
23 tests, 0 failures (2 excluded)
```

## Replay

```
MIX_BUILD_ROOT=_build-ft-ln mix test test/lro_test.exs
MIX_BUILD_ROOT=_build-ft-ln mix test test/enclave_state_test.exs test/smalt_ets_baseline_identity_test.exs \
  test/smalt_ets_composite_identity_test.exs test/arm_error_corpus_test.exs
```

## Full-suite caveat (disclosed, not claimed by this receipt)

Two full `mix test` runs were attempted: run 1 raced this lane's own
in-flight edits plus concurrent lane commits (25 failures, mixed surfaces);
run 2 was stopped at the background time limit mid-run. At the FINAL HEAD
state the failing surfaces reproduce in isolation as: `Smalt.PPlanTest`
leak-tracer on_exit timeout ("did not report within 5s") and
`Smalt.McpWireTest` doctor-vs-doctor.py port-agreement face (5672 free-vs-bind
disagreement) — port/beam contention faces on this shared checkout (8 live
beams observed during the runs), NOT on any LRO surface. The LRO seam is
exercised GREEN at the final state by the two gates above (37/0 and 23/0).
Full-suite green is the coordinator's integration gate, not this lane
receipt's claim.

## Falsifier (how this receipt goes red)

1. Revert `lib/smalt/arm_gateway/lro.ex`'s `get_op/1` to persisting itself
   (call `evaluate/2` directly) → one-writer property dead; fence 10b's
   pre-sweep raw read still passes, but the single-writer disclosure in this
   receipt is false.
2. `LRO.await(id, 0)` raising or wedging instead of `{:error, :timeout}` →
   fence B0-2 red.
3. Kill Notifier mid-await → raise or timeout-without-convergence →
   fence B0-3 red.
4. `LRO.await(foreign_id, other_sub, _)` registering a waiter → B0-4 red.
5. Fence 10d red → convergence no longer owned (emergent again).
