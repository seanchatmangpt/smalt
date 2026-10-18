# r240 — court-x2 attempts 1-2: typed RED, shifting-failure class

Standing: RED (honest, per WO-2: "an honest two-green or an honest typed RED, never a faked pass")
Date: 2026-10-17
Gate: `bash scripts/court_x2.sh` (two fresh `just court` legs; both must be 0 failures)

## Attempts

| Attempt | Log | Run 1 | Run 2 | Failing test (run 1) |
|---|---|---|---|---|
| 1 | tmp/court-x2-v17-wrap.log | RED (1 failure) | GREEN (0 failures) | WasmEngineFailClosedTest "restart hammer under parallel load" (test/affidavit_wasm_failclosed_test.exs:502) + test-sdk-smoke watchdog exit 124 |
| 2 | tmp/COURT_X2_RC line in tmp/court-x2-v17-wrap2.log | RED (1 failure) | GREEN (0 failures) | EgressDispatchTest "batch-list boundary" (test/egress_log_dispatch_test.exs:1221 → test/egress_dispatch_test.exs:1221) |

Both failing tests pass solo 3/3 on the same tree (egress file re-run 3×, 107/0
each; WasmEngine file's face was dispositioned load-class by the flake-face lane).
Both attempt run 1s started within minutes of heavy machine activity (attempt 1:
post-push; attempt 2: overlapping the read-only verify pool's launch). Failure
IDENTITY shifts between attempts — the court_x2.sh shifting-failure alarm
pattern — while the STRUCTURE (cold run 1 trips one load face, warm run 2 green)
is constant. Court ledger: 32 prior invocations, 0 two-green; this window adds
2 RED, same class as r226/r229's "court-environment load class".

## Disposition

- The two tripped faces are typed CONTENTION (timer/teardown races across async
  modules sharing the Store), not product defects: no content failure has ever
  appeared in both runs of an attempt, and every tripped face is solo-green 3/3.
- Attempt 3 (last) will run after a verified-idle quiesce + a warm-up full-suite
  pass, per the cold-run-1 pattern.
- If attempt 3 goes RED on the same class: WO-2 closes honest typed-RED per the
  WORK_ORDERS.md fallback, NEXT_WINDOW carries the gate with this receipt chain.
