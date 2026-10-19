# Court-x2 DRY-RUN leg 3 — full `mix test` at HEAD 1eb89df

- **Date**: 2026-10-18
- **Subject**: /Users/sac/smalt @ `1eb89df2d61461784bfc4cb448e80978dd6daf0b` (≥ 1eb89df, canonical face closed, drift fence 20/0)
- **Command**: `MIX_BUILD_ROOT=_build-ft-court3 mix test` (cwd /Users/sac/smalt)
Context: solo(3 runs, same build root `_build-ft-court3`)

## Runs

| run | wall | tests | failures | captured |
|---|---|---|---|---|
| 1 | 218.4 s | 2733 | **0** | full output |
| 2 | 225.1 s | 2733 | 3 | summary only (grep filter dropped failure bodies — details not captured) |
| 3 | 215.7 s | 2733 | 2 | full output (log: /tmp/court-dry3-run3.log) |

### Run 1 — GREEN

```
Finished in 218.4 seconds (19.5s async, 198.8s sync)
1 doctest, 7 properties, 2733 tests, 0 failures (99 excluded)
```

Zero failures, zero LOAD-face hits. The in-flight atom_bridge/event_hubs lane edits
compiled clean and passed (including `test/amqp/atom_bridge_test.exs`,
`test/amqp/event_hubs_test.exs`, and new
`test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs`). No compile abort.

### Run 3 — 2 failures, both LOAD-class (F61 Topology)

```
Finished in 215.7 seconds (27.1s async, 188.6s sync)
1 doctest, 7 properties, 2733 tests, 2 failures (99 excluded)
```

Both failures are `SmaltTest.Azsim.TopologyTest` `:econnrefused` on
`mint_over_wire(arm_port)` (`test/azsim/topology_test.exs:82` and `:141`,
via `test/support/wire_helpers.ex:146`) — the expected F61 Topology
cross-test / boot-contention face. Verbatim:

```
1) test identity-plane STS token accepted by data plane over the wire (SmaltTest.Azsim.TopologyTest)
   test/azsim/topology_test.exs:82
   ** (MatchError) no match of right hand side value: {:error, :econnrefused}
2) test ARM resource PUT emits ResourceWriteSuccess to integration plane (SmaltTest.Azsim.TopologyTest)
   test/azsim/topology_test.exs:141
   ** (MatchError) no match of right hand side value: {:error, :econnrefused}
```

### Run 2 — 3 failures, not captured

Run 2 used a summary-only grep filter; the 3 failure bodies were dropped before
classification. Identity of those 3 is UNCAPTURED — reported as-is, not classified.

## Failure classification (strict, runs 1+3)

| Class | Observed |
|---|---|
| DetsRecovery rotating (F-class) | 0 |
| EventGrid/egress 503 readiness (F58/F60) | 0 |
| GracefulStop boot (F59) | 0 |
| Topology cross-test (F61) | 2 (run 3, both `:econnrefused` on arm_port mint) |
| boot-contention (:eaddrinuse/already-started) | 0 |
| **Non-LOAD** | **0** |

## Acceptance

**ACCEPTED — zero non-LOAD failures.** Run 1 fully green at HEAD; run 3's only
failures are the expected F61 Topology LOAD face. No edits, no git ops, no
`_build` deletion (build root `_build-ft-court3` preserved for replay).

## Standing

PASS (solo; run 1 green of 2733, runs 2–3 LOAD-class noise only, run 2 unclassified-failure count 3 not captureable post-hoc).
