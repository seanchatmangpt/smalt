# Receipt — cascade (W2a CascadeEdge projection replay fence)

- **Subject:** `/Users/sac/smalt` @ main, HEAD `650a8ff`
- **Standing:** PASS
- **Date:** 2026-10-17

## Subject files

- `lib/smalt/cascade_edges.ex` (generated, DO-NOT-EDIT)
- `test/cascade_replay_identity_test.exs` (fence)
- `ggen-marketplace/packs/smalt-substrate-pack` (CascadeEdge rows)

## Verification (2026-10-17, I2 lane, unedited output)

```
$ mix test test/cascade_replay_identity_test.exs ; echo "exit=$?"
Running ExUnit with seed: 564337, max_cases: 32
Excluding tags: [:amqp_wire]

.....
Finished in 4.6 seconds (0.00s async, 4.6s sync)
5 tests, 0 failures
exit=0
```

## Non-vacuity

Beyond the byte-identity + pack-lock-digest arms shared with the other
fences, the suite runs `verify/cascade-coverage.unbound.rq` with two arms:
(A) referential integrity — every declared edge target exists; (B) cascade
strategy coverage — every representable sweep is declared in the ontology.
An undeclared sweep path (the irregular-tail class W2a fenced) flips arm B;
the verify query is a fail-closed unbound-check, so a missing declaration
exits 1.
