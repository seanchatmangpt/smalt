# Receipt: BK-DLQ3 — event_grid DLQ spill 3-tuple repair (ALIVE)

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-22 · Lane: BK-DLQ3 · Build root: `_build-bkdlq3` ·
Toolchain: `PATH=$HOME/.asdf/shims:$PATH`, MIX_BUILD_ROOT=_build-bkdlq3.

**Subject**: canonical checkout `/Users/sac/smalt`, branch main. Surface:
`lib/smalt/messaging/event_grid.ex` (`write_dlq_blob`/`spill_to_dlq` region).

## Order and disposition

BK-EGDT (receipt `bkegdt-deletion.md`) typed the successor order honestly as
bycatch: `write_dlq_blob`'s case on `BlobStorage.put_blob/6` handled
`{:ok,_}`, 4-tuple, and 2-tuple errors but NOT put_blob's 3-tuples
(`{:error, :worm_locked | :precondition_failed | :too_large, msg}`) — a
reachable CaseClauseError inside the EventGrid GenServer at DLQ-spill time
when the eg-dlq container is WORM-locked. The inverse of dead code.

**Fix**: one pass-through clause in `write_dlq_blob` and one typed retained
arm in `spill_to_dlq` (`{:error, _kind, _msg} = failure` → `report_dlq_write_failure`
+ `{sub, :retained}`) — identical semantics to the existing 2/4-tuple arms:
log the typed reason, keep the event inflight (never loss), timer re-arms.
Zero change to the 2/4-tuple arms' text.

**Compile-freeze disclosure**: the coordinator's tick checkpoint `d8ab6fbe`
absorbed my in-flight `event_grid.ex` fix mid-lane; the working file is
byte-identical to HEAD (sha256 `3d0029f2…`), so this lane's commit carries
the court test + receipt only — the lib diff itself landed in the
coordinator-owned checkpoint.

## Court (Chicago — real collaborators, no mocks)

`test/internal/event_grid_dlq_worm_spill_court_test.exs` — real EventGrid
GenServer, real BlobStorage WORM machinery (container legal hold via the real
`set_legal_hold/3`, the create arm's only create-blocking policy per
blob_storage.ex R5), real Store-backed spill, pacing only through the audited
poll (`SmaltTest.Internal.Poll.eventually`, POLL-STEP). Three legs:

1. **WORM-held DLQ, real spill**: held container + dead subscriber + real
   DOWN timer → put_blob answers `{:error, :worm_locked, "Blob modification
   refused: container has an active legal hold (ContainerLocked)."}` through
   the NEW clause; NO CaseClauseError; GenServer alive; typed
   `event_grid DLQ write failed (event retained) … :worm_locked` logged; the
   event stays inflight pinned at the attempts cap (retained, never loss);
   re-subscribing a live pid recovers it (`{:event_grid, …, "probe-e-1", …}`).
2. **Control (no WORM)**: identical spill on an unlocked container succeeds —
   inflight nil, pending 0, `[:smalt, :event_grid, :dead_lettered]` telemetry
   emitted once, and the failure log is SILENT — the new clause did not
   swallow the success arm.
3. **Direct 3-tuple witness**: `put_blob` on the held container answers the
   exact 3-tuple (non-vacuity at the face level).

## Anti-vacuity (shim-court protocol, swap-probe)

BASELINE sha256 `3d0029f2…` → swap in `d8ab6fbe^` (pre-fix,
zero 3-tuple clauses, verified by grep count 0) → leg 1 FAILS with
`** (CaseClauseError) no case clause matching:` → RESTORE sha256
`3d0029f2…` byte-exact. The court that could not flip would be vacuous; it
flips.

## Verification (real output, this session)

```
$ PATH=$HOME/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-bkdlq3 \
  mix test test/internal/event_grid_dlq_worm_spill_court_test.exs
Result: 2 passed

$ PATH=$HOME/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-bkdlq3 \
  mix test test/integration/eventgrid_push_court_test.exs \
           test/integration/event_grid_webhook_test.exs \
           test/internal/expl5r2_court_test.exs \
           test/internal/event_grid_backpressure_test.exs \
           test/internal/event_grid_dlq_worm_spill_court_test.exs
Result: 24 passed          # 22 pre-existing eventgrid suites + 2 new legs
```

`mix compile` clean for `event_grid.ex` (no new warnings; the two surface
warnings in the tail are pre-existing plug/deps router types, untouched).
