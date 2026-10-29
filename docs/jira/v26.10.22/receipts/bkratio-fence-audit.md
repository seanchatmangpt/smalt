# BK-RATIO — ratio-fence audit of this session's court files

**Standing**: ALIVE (audit; zero violations, zero fixes needed)
**Context**: solo
**Date**: 2026-10-22
**Lane**: BK-RATIO

## Question

BK-FONDSKEP F6-B typed S3's fixed 10s `assert_receive` fence as load-bound
(ratio-fence law violation); BK-FONDSD replaced it with 250ms slices against a
30s monotonic deadline. Do other courts landed this session carry the same
class — a one-shot wall-clock bound standing where a convergence claim needs a
convergence-within-budget poll?

## Census (embedded)

Gates first:

```
$ just sleep-gate
[SLEEP-GATE] PASS — 625 files, 0 unclassified sleep primitives

$ just sleep-gate-court
[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (test + lib +
burn + dual-naming + verification TS/PY + py-allowlist + dual-tree + popcorn
lib/sh/mjs), restore byte-exact
```

Full sweep of `test/internal/*court*`, `test/pipeline/*court*`,
`workspace/scripts/*court*` (73 files) for `assert_receive ..., <N>` with N,
`Process.sleep`, `Task.await <N>`:

```
$ grep -n 'Process\.sleep|assert_receive|Task.await' -E test/internal/*court* test/pipeline/*court* workspace/scripts/*court*
test/internal/bkmaap6_nonce_bounds_court_test.exs:216:  Enum.map(&Task.await(&1, 30_000))
test/internal/eplaw_ephemeral_boot_court_test.exs:72:   Process.sleep(250)
test/internal/eplaw_ephemeral_boot_court_test.exs:103:  Process.sleep(100)
test/internal/ets_auto_court_test.exs:202:              Task.await_many(tasks, :infinity)
test/internal/expl8r_court_test.exs:169:                Task.await(task)
unbounded (hang-guard: test exits if the awaited task deadlocks)
test/internal/expl5r1_court_test.exs:96,103:            Task.await(..., 5_000)
test/internal/gld6_sql_row_gate_court.exs:47:           Process.sleep(100)
test/internal/kd_blob_court_test.exs:56:                Process.sleep(100)
test/internal/powl2_law_guard_court.exs:376:            Task.await/1
test/internal/sql_ingest_wire_court.exs:44:             Process.sleep(100)
test/pipeline/fond_powl_runner_court_test.exs:466:      Task.await(task, 5_000)

$ grep -n 'assert_receive' ... | grep ', *[0-9]'
bkmaap6:186 5_000; bkamqpf:91 10_000; ja15:56,101 5_000;
spofb:39 5_000; fond_powl_runner:105 5_000
```

## Classification — every hit lawful, zero F6-B violations

- **Process.sleep (5 sites)**: all carry `# SLEEP-CLASS: POLL-STEP` and sit
  inside deadline-checked poll loops on a real observable (TCP-accept probe in
  gld6/kd_blob/sql_ingest `wait_listening/2`; eplaw `do_poll/2` with
  `System.monotonic_time` deadline; the eplaw :72 trailing settle is inside
  the child VM-drain eval after `System.stop(0)`, exit awaited by
  `System.cmd` — not a coordination fence). Lawful deadline-bounded polls.
- **Task.await bounds (7 sites)**: hang-guard deadlines on finite tasks (the
  task completes or the test exits) — deadlock containment, not an assertion
  that the world converged by wall clock. fond_powl_runner:466's comment says
  exactly this ("outer bound so the suite cannot hang"). Lawful.
- **assert_receive with N (6 sites)**: `assert_receive` is by construction a
  deadline-checked convergence poll — the observable IS the message; the
  timeout is the budget, not a sleep-and-guess. Largest N is 10_000
  (bkamqpf, waiting on a real `{:bad_frame, ...}` DOWN message from a real
  port crash). Lawful event-driven waits, not F6-B one-shot fences.
- **workspace/*.mjs courts**: every `setTimeout` sleep sits inside a
  deadline-bounded poll (`waitUp`, `waitPortFree`, `stsMint` in kd171r /
  sync-e2e / pattern courts — all `while (Date.now() - t0 < deadlineMs)`
  loops). Remaining `setTimeout(r, N)` uses are simulated workload bodies
  (the body duration is the test input, deterministic in the JS event loop —
  e.g. weblocks/tab-lease serialization legs), or `setTimeout(0)` yields.
  The 10ms settle before the held-lease legs (tab-lease:196,
  weblocks L4) is provably inert: the fake LockManager grants synchronously
  inside `request()` when unheld, so the lease is held before the settle
  even starts; the assertion does not guess at async convergence.
- **bkegs1_fence_court_test.exs** (in-flight, another lane's edit — read
  only): already uses the BK-FONDSD `recv_until_ok/2` 250ms-slice
  deadline-poll idiom; no fixed fence.

## Live witness (real runs, this build root `_build-bkratio`)

```
$ MIX_BUILD_ROOT=_build-bkratio mix test test/pipeline/fond_powl_runner_court_test.exs
Finished in 0.4 seconds
Result: 29 passed

$ MIX_BUILD_ROOT=_build-bkratio mix test test/internal/expl11r2_wps_service_events_court_test.exs test/internal/bkamqpf_f2a_boundary_court_test.exs
Finished in 55.9 seconds
Result: 7 passed
```

The two courts carrying the largest event-driven waits (10s
`assert_receive` on a real port-crash DOWN message; WPS service events)
run green — the class they represent is convergence-within-budget, not
one-shot wall clock.

## Verdict

Zero violations of the ratio-fence law in this session's court files.
The F6-B repair (BK-FONDSD slice-poll) already covers the one instance;
sleep-gate (0 unclassified, 625 files) plus its non-vacuity court hold the
class closed mechanically. No court files edited; no fixes to rerun.
