# R94: error corpus row

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `test/arm_error_corpus_test.exs`, `scripts/gen_error_codes.py` (+81), `docs/ERROR_CODES.md`

## Claim

Corpus row addition/repair landed and is fenced by the ERROR_CODES drift gate.

## Re-run evidence

```
$ mix test test/smalt_arm_gateway_test.exs test/arm_error_corpus_test.exs test/route_negative_test.exs
Finished in 0.4 seconds (0.00s async, 0.4s sync)
62 tests, 0 failures
```

## Verdict

PASS. Corpus tests green (62/0 batch includes arm_error_corpus).
