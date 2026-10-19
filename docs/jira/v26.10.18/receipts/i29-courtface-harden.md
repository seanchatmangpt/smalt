# Receipt: i29-courtface-harden — cross-plane boot-premise faces hardened (GracefulStop pattern)

- **Window**: v26.10.18 / i29
- **Subject**: `test/azsim/topology_test.exs`, `test/wire/arm_wire_test.exs` @ main (no commit; lane-owned diff)
- **Standing**: PASS (both files ×6 green after fix; the two court-x2 run-2 faces structurally closed)
- **Context**: slice(x6)

## Faces (as dispatched)

1. `test/azsim/topology_test.exs:141` "ARM resource PUT emits ResourceWriteSuccess to integration plane"
   — ARM PUT's wire emission races the integration plane's event pipeline warm-up: `bridge_dequeue/2`
   returned `:empty` after only a bounded drain of a queue the event had not reached yet, and
   `mint_over_wire/1` hard-asserted `res.status == 200` before the identity subtree's STS was answering.
2. Identity-plane STS-over-wire face: `test/wire/arm_wire_test.exs` STS faces POST `/oauth2/v2.0/token`
   the instant the supervisor links, racing Bandit listener readiness.

## Fix (structural, no sleeps)

Both premises now use `SmaltTest.AssertEventually.eventually/2` bounded polls on the real observables,
the 82b015e GracefulStop pattern (`test/azsim/graceful_stop_test.exs`):

- `topology_test.exs` `mint_over_wire/1`: bounded poll (10s) on `GenServer.whereis(Smalt.Plane.Identity.StsGate)`
  AND the wire mint answering 200; retries on non-200 or connect failure; typed flunk naming the last
  observed status on timeout. Callers keep matching `{:ok, token} = mint_over_wire(arm_port)` — the poll
  wraps the token as `{:ok, {:ok, token}}` because `eventually/2` unwraps the success tuple one level.
- `topology_test.exs` ARM-PUT test: bridge dequeue wrapped in `eventually/2` (10s) — `:empty` is
  `{:retry, :bridge_queue_empty}` until the `ResourceWriteSuccess` event lands in the bridge queue;
  typed flunk on timeout. All downstream assertions preserved verbatim (event_type, resourceUri,
  Event Grid `assert_receive` 5s, `Peers.refused_connects/0` delta 0).
- `arm_wire_test.exs` setup: bounded poll (10s) that the arm port accepts a real TCP connection
  before any test body runs; typed flunk `arm wire listener answering on <port>` on timeout.

Zero `Process.sleep` added; polls only.

## Verification (real output)

Two intermediate failures during the fix window were **lane-introduced** (the `eventually/2`
success-unwrap shape, fixed in-window); not pre-existing faces.

Post-fix, `MIX_BUILD_ROOT=_build-ft-courtface scripts/fast_test.sh`:

```
test/azsim/topology_test.exs   (x6): 8 tests, 0 failures  (runs 1-6)
test/wire/arm_wire_test.exs    (x6): 6 tests, 0 failures  (runs 1-6)
```

Pre-fix baseline (solo, both faces pass-solo — the flaky shape under court-x2 run 2):

```
test/azsim/topology_test.exs:141 : 1 test, 0 failures (7 excluded)
test/wire/arm_wire_test.exs      : 6 tests, 0 failures
```

## Honesty notes

- The two faces were NOT reproduced failing solo (pass-solo confirmed); the fix converts the
  warm-up race into a bounded observable poll, so run-2 concurrency cannot lose the race silently.
- `scripts/fast_test.sh` manages its own per-hash build root; the `MIX_BUILD_ROOT` env passed is
  advisory (harness overrode it with `_build-ft-<hash>`) — recorded as-is.
- No git actions taken per dispatch.
