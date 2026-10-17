# Receipt — R13 (Event Hubs link-credit over-delivery fix + flip witness)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PARTIAL_ALIVE
- **Date:** 2026-10-15/16, witnessed by the W2 docs lane

## Subject files

- `lib/smalt/messaging/event_hubs.ex` + `lib/smalt/messaging/amqp/connection.ex`
  (credit accounting: the link re-read fix tagged `SHIM-COURT R13/V261014-04-F1 fix`
  at `connection.ex:1456`) — a flow frame granting exactly N credits must
  deliver exactly N of M queued events; pre-fix the link over-delivered.
- Flip witness: `tmp/eh_credit_flip_test.exs` — credit 2, 3 events queued,
  the 3rd must NOT drain.

## Verification (2026-10-15, W2 docs lane, unedited output)

Flip witness (the flip IS the non-vacuity proof):

```
$ mix test tmp/eh_credit_flip_test.exs --include amqp_wire 2>&1 | tail -4
.
Finished in 0.8 seconds (0.00s async, 0.8s sync)
1 test, 0 failures
```

Full EH suite — the claimed "22 tests, 0 failures" does NOT reproduce:

```
$ mix test test/amqp/event_hubs_test.exs --include amqp_wire 2>&1 | tail -4
24 tests, 2 failures
```

Run-to-run: 2 failures → 1 failure → 2 failures across three freeze-free
runs. Failing tests (reproduced):

- `V261014-04 F1 wire-level receiver delivery ...` — test-side
  `<<_::binary-size(14), d>>` pattern never matches the actual 10-byte
  `"eh-event-1"` body (`test/amqp/event_hubs_test.exs:668`,
  FunctionClauseError).
- `GAP-A2-03/04 delivery annotations + x-opt stamps ...` —
  `anns["x-opt-partition-key"] == "pk-42"` got nil
  (`test/amqp/event_hubs_test.exs:782`).

The credit-accounting flip itself is proven non-vacuous by the witness.
Standing PARTIAL_ALIVE until both test-side assertions match the landed
wire behavior (test/ is owned by the R13 repair lane, not this lane).
