# Receipt — R32 (verify-scratch keyvault versioned + release-policy probes)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PASS (after freeze-clear re-run; first run collided with a
  concurrent in-flight `lib/` edit)
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `test/r32_verify_scratch_test.exs` — verify-lane scratch court over the
  KeyVault versioned key surface (`get_key` by version, version list,
  release-policy shape) through `EgressRouter`.

## Verification (2026-10-15, W2 docs lane, unedited output)

First run (collided with in-flight `connection.ex` edit — compile abort,
0 tests executed, not a failure count):

```
$ mix test test/r32_verify_scratch_test.exs > /tmp/r32.out 2>&1; echo "exit=$?"
exit=1
** (CompileError) lib/smalt/messaging/amqp/connection.ex: cannot compile module Smalt.Amqp.Connection
```

Freeze-clear re-run:

```
$ mix test test/r32_verify_scratch_test.exs > /tmp/r32.out 2>&1; echo "exit=$?"; tail -2 /tmp/r32.out
exit=0
5 tests, 0 failures
```

Compile-freeze disclosure: the intermediate aborts were another lane's
in-flight files (`bearer.ex`, `blob_service.ex`, `connection.ex`); no
cross-lane fix was applied by this lane (docs lane, lib/ out of scope).
