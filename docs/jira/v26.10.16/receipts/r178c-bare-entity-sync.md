# R178c — management_rpc bare_entity sync + lock-token array unwrap

Standing: PASS

## Scope

`lib/smalt/messaging/amqp/management_rpc.ex`:

- `bare_entity/1` applied at the entity-name seams (peek
  `queue_from_request || Map.get(body, :queue)`, update-disposition
  `settle_each/6`) so composite/link-qualified names reach the store bare.
- Lock-token decode: AMQP array-of-uuid (`{:array, toks}` from rhea
  wrap_array) unwrapped before `List.wrap/1` — previously the whole tuple
  wrapped as one bogus token and `LockManager.renew/3` raised an uncaught
  FunctionClauseError on the wire.
- GAP-A2-05/06/07 session/DLQ management surface registered in `@sb_ops`
  (set/get-session-state, get-message-sessions, batch-delete-messages).

## Re-run output (docs lane, 2026-10-16, `_build-lane207`)

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/amqp/management_rpc_test.exs
Finished in 0.2 seconds (0.2s async, 0.00s sync)
30 tests, 0 failures (3 excluded)
```

30/0 matches the claimed count. Flip-provenance (the repair lane's
BEFORE/AFTER witness) is recorded in the dispatch chain; the docs-lane
receipt embeds the post-landing re-run per W11 contract.
