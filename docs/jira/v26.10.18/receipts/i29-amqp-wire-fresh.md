# i29 — AMQP wire tier, fresh run (2026-10-18)

- Command: `MIX_BUILD_ROOT=_build-ft-amq mix test --include amqp_wire` (from /Users/sac/smalt, no prior build dir removed)
Context: solo(mix test --include amqp_wire)
- Standing: PARTIAL_ALIVE — 2783 tests + 1 doctest + 7 properties run, 2 failures, 38 excluded

## Summary

```
1 doctest, 7 properties, 2783 tests, 2 failures (38 excluded)
Finished in 221.0 seconds (23.2s async, 197.8s sync)
```

## Failures (verbatim)

```
1) test binary-mode event (ce-* headers + JSON body) is constructed, stored, and round-trips (Smalt.EventGridConformanceTest)
   test/eventgrid_conformance_test.exs:334
   Assertion with == failed
   code:  assert resp.status == 200
   left:  503
   right: 200

2) test stopping the Control subtree terminates the WasmEngine owner typed (not :killed) (Smalt.Azsim.GracefulStopTest)
   test/azsim/graceful_stop_test.exs:73
   WasmEngine owner must be running (app booted)
   code: assert is_pid(owner), "WasmEngine owner must be running (app booted)"
```

One-line causes:

1. `Smalt.EventGridConformanceTest` binary-mode round-trip — expected 200, got 503
   (Event Hubs ingest returned 503; likely egress/ingest dependency unavailable in this boot).
2. `Smalt.Azsim.GracefulStopTest` — WasmEngine owner process not running at test start
   (`is_pid(owner)` false; "app booted" precondition failed, not a `:killed` assertion failure).

## Pinion guards

All AMQP wire pinion assertions unchanged in this run — no test file touched (no edits made):

- SASL ANONYMOUS only — present in test/amqp/*, untouched.
- sasl-outcome descriptor 0x44 — test/amqp/primitive_codec_test.exs, untouched.
- attach top-level <=14 fields (source=8/target=7) — test/amqp/frame_codec_test.exs, untouched.
- .NET-GUID lock-token byte reorder — test/amqp/*, untouched.
- EH fixed partitions ["0","1"] — test/amqp/event_hubs_test.exs, untouched.

None of the 2 failures is in the AMQP wire tier itself; both are EventGrid-conformance and
Azsim graceful-stop suites pulled in by `--include amqp_wire`. Their assertions are
unrelated to the pinion guards above.

## Notes

- Same 2 failures reproduced on two consecutive fresh runs (identical names, same causes).
- Worktree has pre-existing modifications (git status at session start) including
  docs/jira/v26.10.18/test sovereign_midnight files; no files were modified in this session.
