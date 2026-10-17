# R90/R100: TLS pin

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/tls.ex` (+44 diff)

## Claim

TLS pin / cert-chain handling repairs landed.

## Re-run evidence

```
$ mix test test/tls_test.exs test/kv_tls_test.exs
Finished in 2.4 seconds
26 tests, 0 failures
```

## Verdict

PASS. 26/0 over tls + kv_tls. (The 1 failure in the earlier 40-test batch was
telemetry_test, not TLS — see r92.)

## W9 re-citation (2026-10-16, docs lane W9, `_build-lane205`)

Per DoD lane D121: the session figures ("TLS trio 20/0 + fuzz 34/0 x2") were
unlocated. Fresh per-suite counts (unedited output), replacing the combined
session figure:

```
$ MIX_BUILD_ROOT=_build-lane205 mix test test/tls_test.exs
20 tests, 0 failures
$ MIX_BUILD_ROOT=_build-lane205 mix test test/kv_tls_test.exs
7 tests, 0 failures
$ MIX_BUILD_ROOT=_build-lane205 mix test test/amqp/fuzz_test.exs
34 tests, 0 failures
```

Grounded: `test/tls_test.exs` = 20/0, `test/kv_tls_test.exs` = 7/0
(tls+kv_tls combined = 27/0, not the session "26/0"), and the fuzz lane is
`test/amqp/fuzz_test.exs` = 34/0 (a separate suite, not part of the TLS pin
count). Standing: PASS.
