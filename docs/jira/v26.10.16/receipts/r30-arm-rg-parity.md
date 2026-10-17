# R30: ARM resource-group parity

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/arm_gateway/router.ex` (+102 diff)

## Claim

ARM gateway resource-group routing parity repairs landed.

## Re-run evidence

```
$ mix test test/smalt_arm_gateway_test.exs test/arm_error_corpus_test.exs test/route_negative_test.exs
Finished in 0.4 seconds (0.00s async, 0.4s sync)
62 tests, 0 failures
```

## Verdict

PASS. 62/0 over gateway + error-corpus + route-negative.
