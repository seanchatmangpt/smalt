# Receipt — BK-WPS1: WPS-SKEP-1 delivery_result tuple alignment (verification)

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-22 · Lane: BK-WPS1 · Repo: `/Users/sac/smalt`

## Finding and disposition

WPS-SKEP-1 (BK-WPSSKEP) typed the in-flight EXPL-11 F2 edit: `events.ex` casts
4-tuples `{:delivery_result, id, false, "no_handler"}` (events.ex:75/117/120)
while `service.ex:108` matched only the 3-tuple — FunctionClauseError killed
`Smalt.WebPubSub` on every client connect with `handler_url` nil (witnessed 4x
by the skeptic).

**EXPL11-R2 landed its own fix on disk before this lane ran** (task branch 1 —
verification, not repair): `lib/smalt/webpubsub/service.ex:108-127` now accepts
BOTH cast shapes, with a normalization clause delegating the 4-tuple
`{id, delivered?, status}` into the 3-tuple
`{id, {:delivered, code} | {:refused, reason} | {:no_handler, nil}}` contract.
`events.ex` senders unchanged (4-tuples), `git status` shows `service.ex` /
`events.ex` clean (already committed). This lane edited NO `lib/` file.

## Verification 1 — direct cast probe (real GenServer, `mix run --no-start`, no mocks)

Bare `Smalt.WebPubSub` broker booted alone (`--no-start`; shared substrate held
the fixed ports), then the exact kill shapes cast directly:

```
$ MIX_BUILD_ROOT=_build-bkwps1 mix run --no-start /tmp/bkwps1_cast.exs
exit=0
GENSRV ALIVE after no_handler casts: true
SAME PID: true
DOWN received: false
```

Casts used: the 4-tuple no_handler shape `{:delivery_result, "probe-1", false,
"no_handler"}` (the witnessed kill pre-fix), the tagged 3-tuple
`{:no_handler, nil}`, and `{:refused, :econnrefused}`. Broker alive, same pid,
no :DOWN — no crash-and-restart (pre-fix this was FunctionClauseError → broker
death → supervised restart wiping groups + witness buffer).

## Verification 2 — court suite with the new aliveness leg

BK-WPSSKEP named the coverage gap: the 25-test WPS suites passed DESPITE the
kill because no leg asserted broker aliveness post-connect. Added one leg to
`test/internal/expl11r2_wps_service_events_court_test.exs`
(`WPS-SKEP-1: broker survives connect with handler_url nil`): real
`Events.connect/3` with `handler_url` nil, real `no_handler` cast lands, witness
flips to `delivery_status == "no_handler"`, then pins the broker pid: no
`{:DOWN, ...}` monitor message, `Process.alive?`, and `whereis` identity. A
regression of this class (any unhandled cast on the connect path) now fails the
court instead of passing silently.

```
$ MIX_BUILD_ROOT=_build-bkwps1 bash scripts/fast_test.sh \
    test/internal/expl11r2_wps_service_events_court_test.exs \
    test/internal/wps_exp4_court_test.exs \
    test/internal/kd169r_cred_gate_test.exs \
    test/internal/webpubsub_test.exs \
    test/internal/expl11r_court_test.exs \
    test/internal/expl11r3_court_test.exs
Finished in 10.6 seconds (0.00s async, 10.6s sync)
Result: 40 passed          (incl. the new WPS-SKEP-1 aliveness leg, 05:48Z 2026-10-22)
```

## Files

- `test/internal/expl11r2_wps_service_events_court_test.exs` — added
  WPS-SKEP-1 aliveness leg (only file this lane edited).
- No `lib/` edit; the fix is EXPL11-R2's, verified here against the skeptic's
  falsifier (`GENSRV ALIVE after no_handler cast: true`).

## WPS-SKEP-1 closure

The broker-kill defect is closed WITH EVIDENCE: fix landed (EXPL11-R2),
falsifier re-run negative (no kill), and the tautology-shaped coverage gap
BK-WPSSKEP flagged is closed with a permanent aliveness leg. WPS surface
standing rises from PARTIAL_ALIVE (05:45Z) to ALIVE as of this receipt.
