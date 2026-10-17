# Receipt — R6 (QueueStore do_deadletter self-call fix)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-15 (witness re-run by W1 wave-2 docs lane)

## Subject files

- `lib/smalt/messaging/amqp/queue_store.ex` (`do_deadletter/5`, call sites at
  lines 534 / 666; SHIM-COURT R6 marker at line 694)
- `test/amqp/queue_store_test.exs`

## Defect

`do_deadletter/5` was invoked via a self-call that ran outside the serialized
GenServer context on the max-delivery sweep path, racing the claim bookkeeping
instead of routing through the `GenServer.call` reply at line 534.

## Fix

The sweep path now routes through the serialized handle_call entry point
(`SHIM-COURT R6` marker at `queue_store.ex:694` documents the deadletter runs
INSIDE the serialized QueueStore).

## Verification (re-run 2026-10-15 by W1 wave-2 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane1 mix test test/amqp/queue_store_test.exs
...
Finished in 1.1 seconds (0.00s async, 1.1s sync)
37 tests, 0 failures
```

Note (disclosed, cross-lane): the first attempt at this run hit a transient
compile abort in `lib/smalt/data_plane/cosmos.ex` (TokenMissingError, unclosed
delimiter — another lane's in-flight edit, compile-freeze SLA). After the owner
landed the fix (~2 min), `mix compile` succeeded and the run above went green
on the same tree. The compile abort was not on the R6 surface.
