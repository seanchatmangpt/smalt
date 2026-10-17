# I18: store_dets churn test — quiet-tree confirmation

Standing: PASS (quiet-tree 4/4; r229 flake classified contention-class, not a code defect)

Lane I18, lease test/ (verify-only). Subject: `test/store_dets_test.exs:145`
(DETS store churn/restore). Coordinator previously ran this solo 3/3 PASS on
a quiet tree (~93-95s each); this lane adds one fresh confirmation run.

Note: `scripts/fast_test.sh` uses its own per-hash private build root
(`_build-ft-b90c19fb` for this file set); the `MIX_BUILD_ROOT=_build-lane18`
env is superseded by the script's design (per CLAUDE.md test ladder).

## Fresh confirmation run (2026-10-17, lane I18)

```
$ MIX_BUILD_ROOT=_build-lane18 scripts/fast_test.sh test/store_dets_test.exs:145
14:42:55.452 [info] Running Smalt.ArmGateway.Router with Bandit 1.13.1 at 127.0.0.1:59771 (http)
14:42:55.531 [info] Running Smalt.Application.TlsTwinDispatch with Bandit 1.13.1 at 127.0.0.1:59772 (https)
14:42:55.540 [info] Running Smalt.EgressRouter with Bandit 1.13.1 at 127.0.0.1:59773 (http)
14:42:55.545 [info] Running Smalt.Mcp.Router with Bandit 1.13.1 at 127.0.0.1:59776 (http)
14:42:55.550 [info] [amqp] sb listener bound on port 59774
14:42:55.550 [info] [amqp] eh listener bound on port 59775
Running ExUnit with seed: 597560, max_cases: 32
Excluding tags: [:test]
Including tags: [location: {"test/store_dets_test.exs", 145}]

.
Finished in 204.3 seconds (0.00s async, 204.3s sync)
1 test, 0 failures (5 excluded)
[14:46:20] wall: 210s (build root: _build-ft-b90c19fb)
```

## Runs ledger

| run | conditions | result | duration |
|---|---|---|---|
| 1-3 | coordinator, solo, quiet tree | 3x PASS | ~93-95s each |
| 4 | lane I18 confirmation (this receipt) | PASS, 1 test 0 failures | 204.3s test / 210s wall |

## Classification

r229 flake = contention-class. The test passes consistently (4/4) when the
tree is quiet; no failure reproduced under solo execution. The 204s run vs
~93s coordinator runs reflects concurrent lane load on the shared checkout
during this confirmation, not a behavioral change.

Falsifier for the contention classification: reproduce the failure under
solo quiet-tree execution. Not observed in 4 runs.
