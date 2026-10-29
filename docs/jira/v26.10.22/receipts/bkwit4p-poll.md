# BK-WIT4P — BK-WIT4 witness-all liveness poll

- **Standing**: ALIVE (PROGRESSING — no relaunch, no reap)
- **Context**: solo
- **Date**: 2026-10-22 07:36–07:38 PDT
- **Lane**: BK-WIT4P (read-only census lane)

## Census

`ps` at 07:36:41 — witness-all run is live:

```
sac 21551 ... S  7:30AM 0:00.35 Python scripts/witness_all.py
sac 21536 ... S  7:30AM 0:00.01 just witness-all
sac 21535/21527 zsh -c ... (just witness-all > /tmp/bkwit4-witness-all.out 2>&1; echo "EXIT=$?" >> ...)
```

Output log `/tmp/bkwit4-witness-all.out` mtime 07:36 (current), and **growing**:
325 lines at first poll → 341 lines after 45s. Not stale, not FROZEN.

Receipt `docs/jira/v26.10.22/receipts/bkwit4-witness-final.md` — **not landed yet**
(dir listing shows bkwit2/bkwit3 finals only).

## Mid-run observations (embedded, informational)

The run is actively emitting mixed verdicts:

```
[WITNESS-RUN] docs/jira/v26.10.22/receipts/bkcens2-registration2.md class=mix-test cmd=MIX_BUILD_ROOT=_build-bkcens2 mix test test/internal/internal_tier_census_test.exs
[WITNESS-RED] docs/jira/v26.10.22/receipts/bkcens2-registration2.md exit=2 :: ... Smalt.EgressRouter.do_match/4
[WITNESS-RUN] docs/jira/v26.10.22/receipts/bkcens4-wave4.md class=mix-test ... [WITNESS-RED] exit=2
[WITNESS-STALE] docs/jira/v26.10.22/receipts/bkcens5-wave5.md no rerunnable command in receipt (standing: ALIVE)
[WITNESS-FAIL] docs/jira/v26.10.14/receipts/01-test-isolation.md NO-STANDING   (v26.10.14 window swept too)
```

## Verdict

**PROGRESSING** — BK-WIT4 is live and advancing; coordinator should wait for its
completion notification rather than relaunch. `bkwit4-witness-final.md` landing is
the completion signal.

## Note for coordinator

The run is emitting `[WITNESS-RED] exit=2` (compile-abort-class, EgressRouter) and
`[WITNESS-STALE]`/`[WITNESS-FAIL] NO-STANDING` rows — those are witness results, not
run-liveness failures; final receipt will carry the tallies.
