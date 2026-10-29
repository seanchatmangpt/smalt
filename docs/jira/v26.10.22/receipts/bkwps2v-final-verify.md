# Receipt — BK-WPS2V: WPS-SKEP-1 final verification (third pass, merged tree)

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-22 · Lane: BK-WPS2V · Repo: `/Users/sac/smalt`

Third independent verification pass on the fully-merged tree (HEAD 62ea9575).
All four legs hold; no `lib/` or test file edited by this lane.

## (1) Court + WPS suites fresh on HEAD

```
$ MIX_BUILD_ROOT=_build-bkwps2v bash scripts/fast_test.sh \
    test/internal/expl11r2_wps_service_events_court_test.exs \
    test/internal/wps_exp4_court_test.exs \
    test/internal/kd169r_cred_gate_test.exs \
    test/internal/webpubsub_test.exs \
    test/internal/expl11r_court_test.exs
Result: 33 passed
```

## (2) BK-WPSSKEP original falsifier re-run (bare broker cast probe)

`/tmp/bkwps1_cast.exs` (BK-WPS1's probe, unchanged): bare `Smalt.WebPubSub`
broker via `GenServer.start_link` (`mix run --no-start`; shared substrate holds
the ports), then the exact WPS-SKEP-1 kill shapes cast directly — the 4-tuple
no_handler shape `{:delivery_result, "probe-1", false, "no_handler"}` plus the
tagged 3-tuples `{:no_handler, nil}` / `{:refused, :econnrefused}`.

```
$ MIX_BUILD_ROOT=_build-bkwps2v mix run --no-start /tmp/bkwps1_cast.exs
GENSRV ALIVE after no_handler casts: true
SAME PID: true
DOWN received: false
exit=0
```

No crash, no restart (pre-fix: FunctionClauseError → broker death on connect
with nil handler_url).

## (3) Aliveness leg present

```
test/internal/expl11r2_wps_service_events_court_test.exs:
40:  # -- BK-WPSSKEP / WPS-SKEP-1: broker aliveness post-connect (anti-tautology) ------
46:  test "WPS-SKEP-1: broker survives connect with handler_url nil (no_handler cast)" do
72:    assert Process.alive?(broker)
```

## (4) Census registration green on final files

```
$ MIX_BUILD_ROOT=_build-bkwps2v bash scripts/fast_test.sh \
    test/internal/internal_tier_census_test.exs
Result: 6 passed
```

## Verdict

WPS-SKEP-1 stays closed WITH EVIDENCE on the merged tree: fix (EXPL11-R2) live
in `lib/smalt/webpubsub/service.ex`, falsifier negative (broker ALIVE, same
pid, no :DOWN), aliveness leg present and passing, census 6/6 green. WPS
surface standing holds at ALIVE.
