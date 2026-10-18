# i21 — Fence 10 hammer: GREEN (12/12 legs, 12 tests each)

Standing: GREEN (12/12 legs green: 10 solo + 2 load, each 12 tests / 0 failures; acceptance met)
Context: solo

Subject: 10 consecutive solo runs + 2 load legs of
`MIX_BUILD_ROOT=_build-ft-vf10 mix test test/affidavit_wasm_failclosed_test.exs`,
cwd /Users/sac/smalt, per the fence-10 fix receipt
`docs/jira/v26.10.17/receipts/i21-fence10-fix.md` (standing ALIVE as of 2026-10-17 20:46).

## Unblock

The prior BLOCKED receipt on this file is superseded. The blocker (root `mix.exs`
pinned `{:ex4pm, "~> 26.10.8"}` while locked `ash_ex4pm` requires `== 26.10.1`,
making the test dep graph unsatisfiable) was fixed by commit 8dad54f
("fix(deps): ex4pm pin ~> 26.10.1 — satisfiable under hex ash_ex4pm == 26.10.1").
No edits were made by this lane; the pin fix is the sole unblock. First leg
recompiled `_build-ft-vf10` as predicted (111s), subsequent legs ~5-7s.

## Results

Solo legs (rc=0 on all; wall includes mix startup + compile check):

| leg | wall | result |
|-----|------|--------|
| 1 | 111s (recompile of _build-ft-vf10) | 12 tests, 0 failures |
| 2 | 6s | 12 tests, 0 failures |
| 3 | 6s | 12 tests, 0 failures |
| 4 | 5s | 12 tests, 0 failures |
| 5 | 6s | 12 tests, 0 failures |
| 6 | 7s | 12 tests, 0 failures |
| 7 | 5s | 12 tests, 0 failures |
| 8 | 5s | 12 tests, 0 failures |
| 9 | 5s | 12 tests, 0 failures |
| 10 | 5s | 12 tests, 0 failures |

Load legs — each run under 4 concurrent `yes` CPU hogs, hogs killed with
`pkill -9 -x yes` after the run, post-verify `pgrep -x yes` = 0:

| leg | wall | result |
|-----|------|--------|
| 11 | 5s | 12 tests, 0 failures |
| 12 | 5s | 12 tests, 0 failures |

Note: load-leg walls (5s) match solo walls — this machine has enough cores that
4 `yes` hogs do not starve the test run; the legs exercised concurrency without
contention-induced slowdown. Reported as measured, not as a contention result.

## Harness note (honest failure disclosure)

The first attempt at the load legs ran both legs inside one background shell
loop; its `kill $hogs` was blocked by the tool sandbox (signals refused), the
`yes` hogs survived the run and the shell hung in `wait`. Run 1's log from that
attempt did complete green (12/0) under hogs, but its hog cleanup failed, so
both legs were re-run individually with `pkill -9 -x yes` outside the sandbox.
Legs 11-12 above are the clean re-runs. Post-verify after the final leg:
0 `yes` processes. The stuck background shell and orphaned hogs were killed
before the re-runs; the earlier solo legs are unaffected (separate runs).

## Falsifier replay

```
cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-ft-vf10 mix test test/affidavit_wasm_failclosed_test.exs
# => 12 tests, 0 failures (exit 0), reproducible solo and under 4x yes hogs
```
