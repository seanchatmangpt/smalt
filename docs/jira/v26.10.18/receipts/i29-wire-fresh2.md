# i29 — Wire tier 2x fresh at HEAD

- **Context**: slice(amqp_wire x2)
- **Subject**: /Users/sac/smalt @ HEAD `1a309e2` (>= 2106032 satisfied). Working tree carried in-flight lane edits (`lib/smalt/messaging/event_hubs.ex`, `lib/smalt/plane/integration_supervisor.ex`, `test/test_helper.exs`, etc. per `git status`) — run is at working tree, not a clean HEAD checkout.
- **Command** (both runs, cwd /Users/sac/smalt):
  `MIX_BUILD_ROOT=_build-ft-w4 mix test --include amqp_wire`
- **Build root**: `_build-ft-w4` used as instructed; no `_build` dir removed.

## Results

| Run | Outcome | Detail |
|---|---|---|
| 1 | FAIL — 3 failures | `1 doctest, 7 properties, 2789 tests, 3 failures (32 excluded)` — 224.9s. Failure identities not captured (output only tailed); log discarded. |
| 2 | FAIL — 2 failures + 1 invalid | exit 2; `1 doctest, 7 properties, 2789 tests, 2 failures, 1 invalid (32 excluded)` — 224.5s. Full log: /tmp/w4_run2.log |

### Run 2 failures (with log lines)

1. **INVALID (setup_all)** — `Smalt.Chaos.CrashIsolationTest` — `/tmp/w4_run2.log:5254`:
   `eventually("ARM listener answering"): not satisfied within 5000ms (after 28 pass(es)) — last value: :retry` (test/chaos/crash_isolation_test.exs:34)
2. **FAIL** — `SmaltTest.Azsim.DetsRecoveryTest` "graphlaw/WasmEngine killed mid-request..." test/azsim/dets_recovery_test.exs:237 — `/tmp/w4_run2.log:7688`:
   `eventually("WasmEngine restarted after kill"): not satisfied within 5000ms (after 29 pass(es)) — last value: :down` (line 277)
3. **FAIL** — `Smalt.CanonicalProjectionTest` "docs/capabilities.json equals rendered json/0" test/canonical_projection_test.exs:134 — `/tmp/w4_run2.log:24860`:
   `docs/capabilities.json is stale vs Registry truth` — pre-existing drift at this HEAD (docs/capabilities.json unmodified in git status; registry truth moved without projection regenerate).

## Known-face classification

- Neither named known face recurred: **no EventGrid 503**, **no GracefulStop owner-not-booted** line in either run's summary. The run-2 faces are a different set (bounded-poll timeouts in chaos/dets-recovery setup + a projection drift fence).
- Note: run 1 had 3 failures with identities uncaptured; run 2's set may overlap partially.

## Pinions (code-level verification at this tree, all hold)

- SASL ANONYMOUS — lib/smalt/messaging/amqp/connection.ex:7,50
- sasl-outcome 0x44 — lib/smalt/messaging/amqp/frame_codec.ex:69; primitive_codec.ex:59,272
- attach top-level <= 14 — lock_manager/connection descriptor construction unchanged; no attach-arity failures in either run
- .NET-GUID lock-token reorder — lib/smalt/messaging/amqp/lock_manager.ex:61-86
- EH fixed partitions ["0","1"] — lib/smalt/messaging/amqp/management_rpc.ex:62,92; connection.ex:640

## Standing

**SUSPECT** — wire tier not green on either fresh run; failures are bounded-poll (AssertEventually 5000ms) timing faces under machine load plus one real pre-existing projection drift (`docs/capabilities.json` stale). No wire-protocol regressions observed.
