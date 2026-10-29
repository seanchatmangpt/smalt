# Receipt: BK-EGDT — event_grid dead-tail deletion (REFUSED — premise rot)

**Standing**: surface ALIVE as-is; deletion REFUSED (no provably-dead tail on the current tree)
**Context**: solo
**Date**: 2026-10-22 · Lane: BK-EGDT · Build root: `_build-bkegdt` ·
Toolchain: OTP/Elixir via `PATH=$HOME/.asdf/shims:$PATH`.

**Subject**: canonical checkout `/Users/sac/smalt`, branch main. No edits to
`lib/` this lane — zero-diff elimination audit.

## Dispatch premise and its disposition

The lane was dispatched to delete a "dead tail" in the event_grid surface file
(`lib/smalt/messaging/event_grid.ex`, BK-WIT3R/ARM4 lineage). The falsifier
clause was explicit: if the tail turns out reachable, STOP and type the
finding instead of forcing the deletion. It is reachable. Nothing is deleted.

## Audit — every dead-tail candidate examined and typed reachable

Surface files: `lib/smalt/messaging/event_grid.ex`,
`lib/smalt/event_grid_webhook.ex`, `lib/smalt/eventgrid/push_router.ex`.

1. **Compiler premise is false on this tree.** A forced recompile of all three
   surface files (touch + `mix compile`, `_build-bkegdt`) emits ZERO warnings
   for any of them — no "clause cannot match", no unused-variable, no
   unreachable-pattern warnings. The only "cannot match" warning in the build
   (`Smalt.DataPlane.Cosmos.effective_ttl` consumer, lib/smalt/data_plane/cosmos.ex) is
   pre-existing and owned by another surface, untouched.
2. **`write_dlq_blob`/`spill_to_dlq` `{:error, _kind}` 2-tuple clauses** —
   reachable: `BlobStorage.put_blob/6` returns the 2-tuple
   `{:error, :container_not_found}` (`lib/smalt/data_plane/blob_storage.ex`,
   put_blob else-branch), which both clauses must catch.
3. **`ensure_dlq_container` `{:error, 409, "ContainerAlreadyExists", _} -> :ok`**
   — reachable under create-race (documented in the clause's own comment).
4. **`prune_order`/`prune_queue` `{:empty, _}` defensive clauses** — reachable
   under a negative configured cap (`:max_queue_len`/`:max_seen_ids` are
   user-overridable via config, cap < 0 keeps the recursion alive at empty).
5. **Every `handle_call`/`handle_info` clause** — reachable from live callers:
   `publish` (egress_router.ex:4421 + backpressure tests), `subscribe`/`ack`/
   `status`/`reset` (backpressure + webhook tests), the DOWN→`arm_retry`→
   `{:redeliver, topic, name}` path (mark_down), the DLQ-on and DLQ-off
   `{:redeliver}` branches, and both `envelope` schema clauses (push court +
   webhook tests exercise both schemas).
6. **Every public function of the webhook and push_router modules** has live
   callers (tests count; grep receipts in session log): `register`, `unregister`
   (event_grid_webhook_test), `delivered`/`delivered?`, `PushRouter.ingest`
   (expl5r2 + expl10r2 courts), `deliveries`, `counters`, `delete_subscription`,
   subscription REST face (push court), `PushRouterPlug.call/2` (mounted in
   EgressRouter, exercised through the real router in the push court).
7. **`PushRouter.deliver/4`'s `{:error, :store_not_ready}` clause** — reachable
   (`QueueStorage.ready!/0` returns exactly that 2-tuple; queue_storage.ex:63).

## Incidental typed finding (the inverse of dead code — an unhandled reachable shape)

`write_dlq_blob`'s case on `BlobStorage.put_blob/6` handles `{:ok, _}`, 4-tuple
errors, and 2-tuple errors — but put_blob ALSO returns 3-tuples
(`{:error, :worm_locked, msg}`, `{:error, :precondition_failed, msg}`,
`{:error, :too_large, msg}`, blob_storage.ex put_blob body). A 3-tuple matches
neither error clause → CaseClauseError inside the GenServer at DLQ-spill time.
Reachable when the DLQ container is WORM-locked (the blob-worm invariant gate
can lock `eg-dlq*` containers) or the payload trips the 1 MiB cap. Not fixed
this lane (no wire to change was in scope); typed here as the successor order.

## Verification (real output, this session)

```
$ PATH=$HOME/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-bkegdt \
  mix compile   # after touching all three event_grid surface files
→ zero warnings for lib/smalt/messaging/event_grid.ex,
  lib/smalt/event_grid_webhook.ex, lib/smalt/eventgrid/push_router.ex

$ PATH=$HOME/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-bkegdt \
  mix test test/integration/eventgrid_push_court_test.exs \
           test/integration/event_grid_webhook_test.exs \
           test/internal/expl5r2_court_test.exs \
           test/internal/event_grid_backpressure_test.exs
Finished in 0.3 seconds
Result: 22 passed
```

Callers verified intact by the green suites themselves (push court runs through
the real EgressRouter; backpressure tests drive publish/subscribe/ack/status on
messaging/event_grid.ex directly).

## Disposition

ERRC Eliminate requires a provable deletion; the premise does not hold on the
current tree. Per the lane's own falsifier: STOP, type, do not force. Zero
edits to `lib/`. Nothing committed for `lib/smalt/messaging/event_grid.ex`
because there is nothing to commit — this receipt IS the deliverable.
