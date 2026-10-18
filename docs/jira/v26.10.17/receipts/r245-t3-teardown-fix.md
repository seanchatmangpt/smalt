# r245 — T3 sdk-smoke teardown deadlock root-caused + fixed; leg green

Standing: PASS
Date: 2026-10-17
Context: solo (3 runs by the i21c lane + 1 post-fix verification run)

## Root cause (i21c-t3-sdk-smoke.md finding, fix applied by coordinator)

`test/sdk-smoke/run.mjs` set `process.exitCode` instead of calling
`process.exit`. The spawned `mix run --no-halt` beam child keeps node's event
loop referenced, so the "exit" teardown event never fires and the recorded
exit code is never consulted — the harness hung after a fully green 286ms
probe set until the court watchdog killed it (the witnessed exit 124 in court
attempt 1 and multiple prior-window logs). Fix: hard `process.exit(...)` at
run.mjs:288 forcing the SIGTERM/exit teardown path (killSubstrate +
enforce kill).

## Verification (real output)

Post-fix `just test-sdk-smoke`, ports verified free pre-run:
`pass 7 / fail 0 / duration_ms 1224` — exit 0, teardown immediate, no orphan
beams (port sweep clean).

## Disposition

- The T3 exit-124 class (court attempt 1; runs 13/21/25/31 of prior windows)
  is closed: it was harness teardown deadlock, never a probe failure.
- Court T3 leg expected green in attempt 4; stage time drops from ≤1800s to
  seconds-to-minutes.
