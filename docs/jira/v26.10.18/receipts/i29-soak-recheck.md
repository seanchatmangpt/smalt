# i29 — soak recheck at HEAD 806d86e

Context: slice(corpus+compliance x2; amqp_wire x2 — first run + failure-detail re-run)
Date: 2026-10-18
Repo: /Users/sac/smalt

## Command + output

```
$ git rev-parse --short HEAD
806d86e

$ MIX_BUILD_ROOT=_build-ft-cs6 mix test test/corpus_test.exs test/compliance_test.exs   # run 1
182 tests, 0 failures (17 excluded)   # 21.4s

$ MIX_BUILD_ROOT=_build-ft-cs6 mix test test/corpus_test.exs test/compliance_test.exs   # run 2
182 tests, 0 failures (17 excluded)   # 21.7s

$ MIX_BUILD_ROOT=_build-ft-w7 mix test --include amqp_wire   # run 1
1 doctest, 7 properties, 2794 tests, 1 failure (38 excluded)   # 151.4s

$ MIX_BUILD_ROOT=_build-ft-w7 mix test --include amqp_wire   # run 2 (failure-detail capture)
1 doctest, 7 properties, 2794 tests, 1 failure (38 excluded)
```

## Result

- Tier 1 (corpus + compliance): 182/0 twice — matches baseline 182/0. PASS.
- Tier 2 (amqp_wire): 2794 tests, **1 failure**, identical on both runs — deterministic,
  not flaky:

```
1) test stopping the Control subtree terminates the WasmEngine owner typed (not :killed)
   (Smalt.Azsim.GracefulStopTest)
   test/azsim/graceful_stop_test.exs:73
   "WasmEngine owner must be running (app booted)"
   code: assert is_pid(owner), "WasmEngine owner must be running (app booted)"
   test/azsim/graceful_stop_test.exs:75
```

## Classification

LOAD-roster classification (per test/azsim/graceful_stop_test.exs — pre-existing at HEAD,
not session-introduced: no edits made this session):

- Surface: graceful-stop / WasmEngine owner liveness under the full amqp_wire load tier.
- The assertion is a precondition (`assert is_pid(owner)` at setup line 75 of the test) —
  the WasmEngine owner process is not a pid by the time the test runs under full-suite
  load, i.e. the engine either failed to boot or was already terminated when the Control
  subtree stop sequence reaches it. The typed-termination claim itself was never reached.
- Fails only in the full `--include amqp_wire` tier context (tier-1 runs and the offline
  suite are unaffected); consistent with a load-ordering / shared-state interference
  class rather than a pinion regression — no SASL/attach/lock-token/EH-partition pinion
  failures in either run.

Standing: SUSPECT — amqp_wire tier carries 1 deterministic failure at 806d86e
(Smalt.Azsim.GracefulStopTest, graceful_stop_test.exs:73); all 2793 other tests plus
doctest and 7 properties pass; tier-1 corpus/compliance clean twice.
