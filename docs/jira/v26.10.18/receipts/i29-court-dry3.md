# Court-x2 DRY-RUN leg 3 — full `mix test` at HEAD 1eb89df

- **Date**: 2026-10-18
- **Subject**: /Users/sac/smalt @ `1eb89df2d61461784bfc4cb448e80978dd6daf0b` (≥ 1eb89df, canonical face closed, drift fence 20/0)
- **Command**: `MIX_BUILD_ROOT=_build-ft-court3 mix test` (cwd /Users/sac/smalt)
- **Context**: solo

## Result

```
Finished in 218.4 seconds (19.5s async, 198.8s sync)
1 doctest, 7 properties, 2733 tests, 0 failures (99 excluded)
```

Exit 0. **Zero failures, zero LOAD-face hits.** No compile aborts — the in-flight
atom_bridge/event_hubs lane edits compiled clean and passed (including
`test/amqp/atom_bridge_test.exs`, `test/amqp/event_hubs_test.exs`, and the new
`test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs`).

## Failure classification (strict)

| Class | Expected faces | Observed |
|---|---|---|
| DetsRecovery rotating (F-class) | — | 0 |
| EventGrid/egress 503 readiness (F58/F60) | — | 0 |
| GracefulStop boot (F59) | — | 0 |
| Topology cross-test (F61) | — | 0 |
| boot-contention (:eaddrinuse/already-started) | — | 0 |
| **Non-LOAD** | — | **0** |

## Acceptance

Zero non-LOAD failures — **ACCEPTED**. Leg 3 green at current HEAD; no
edits, no git ops, no `_build` deletion performed (build root
`_build-ft-court3` preserved for replay).

## Standing

PASS (solo, single warm run; cold-start build of `_build-ft-court3` included in the 218.4 s wall).
