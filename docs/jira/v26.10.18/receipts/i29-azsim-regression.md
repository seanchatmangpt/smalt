# i29 — azsim regression run

Context: slice(12-file azsim suite, one invocation)
Standing: PARTIAL_ALIVE — the 73-test azsim suite (12 files) is green on most runs, with two defects on this subject: (a) `sovereign_midnight_test.exs` cannot compile (pre-existing, untracked file, out of lane scope — no edits allowed); (b) `plane_supervision_test.exs` carries a real, reproduced flake (eaddrinuse on DataSupervisor restart) that cascades to 29 failures in batch runs.

Scope: regression run only — no edits, no git. Receipt context: slice.

## Verbatim command output

Batch, 12 files (sovereign_midnight excluded — it compile-aborts the whole batch):

```
$ MIX_BUILD_ROOT=_build-ft-az2 mix test test/azsim/adversarial_joe_test.exs test/azsim/amqp_saturation_test.exs test/azsim/azure_common_issues_test.exs test/azsim/control_plane_test.exs test/azsim/data_plane_test.exs test/azsim/dets_recovery_test.exs test/azsim/dr_scenarios_test.exs test/azsim/graceful_stop_test.exs test/azsim/identity_plane_test.exs test/azsim/integration_plane_test.exs test/azsim/plane_supervision_test.exs test/azsim/topology_test.exs
Finished in 2.8 seconds (0.00s async, 2.8s sync)
73 tests, 1 failure (3 excluded)
```

Repeat runs of the identical 12-file batch: `73 tests, 0 failures` (4 runs), `73 tests, 1 failure` (1 run), `73 tests, 29 failures` (1 run). Logs: `/tmp/azsim_run.log`, `/tmp/azsim_run_{1..4}.log`.

Solo sovereign_midnight (deterministic, exit 1 every attempt):

```
$ MIX_BUILD_ROOT=_build-ft-az2 mix test test/azsim/sovereign_midnight/sovereign_midnight_test.exs
== Compilation error in file test/azsim/sovereign_midnight/sovereign_midnight_test.exs ==
** (Code.LoadError) could not load /burn-evidence/test/support/assert_eventually.ex. Reason: enoent
    (elixir 1.19.5) lib/code.ex:2339: Code.find_file!/2
    test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1: (file)
```

Plane-supervision solo flake-rate, 10 runs:

```
$ for i in 1..10: MIX_BUILD_ROOT=_build-ft-az2 mix test test/azsim/plane_supervision_test.exs
2 tests, 0 failures   (x9)
2 tests, 1 failure    (x1, run 6)
```

## Defect 1 — sovereign_midnight compile abort (pre-existing, out of lane scope)

`test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1`:

```elixir
Code.require_file("test/support/assert_eventually.ex", "/burn-evidence")
```

The base path `/burn-evidence` does not exist on this machine, so the file fails to compile and `mix test test/azsim/` exits 1 before running any test. This is the same defect class fixed for `azure_common_issues_test.exs` in commit dda0bf5 ("require path — __DIR__ relative, not nonexistent /burn-evidence"); the untracked sovereign_midnight file still carries the stale variant. The lane contract was no-edits, so it is reported, not fixed. Fix shape (for the owning lane): the helper is already loaded via test helpers — `import SmaltTest.AssertEventually` like `dr_scenarios_test.exs:35` does, or a `__DIR__`-relative require.

## Defect 2 — plane_supervision eaddrinuse flake (real, reproduced, root cause characterized)

Verbatim failure (identical in batch and solo runs):

```
1) test terminating DataSupervisor leaves ControlSupervisor alive and serving requests (Smalt.Azsim.PlaneSupervisionTest)
   test/azsim/plane_supervision_test.exs:22
   match (=) failed
   code:  assert {:ok, _} = Supervisor.restart_child(Smalt.Supervisor, DataSupervisor)
   left:  {:ok, _}
   right: {:error,
           {:shutdown,
            {:failed_to_start_child,
             {Bandit, #Reference<...>},
             {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}}}}
```

- Rate: ~1 in 10 solo runs of `plane_supervision_test.exs`; in batch it is the sole failure (~1-2 of 6 batch runs) and additionally cascades: DataSupervisor stays down → shared Store tables never come up → `dr_scenarios_test.exs:47` setup `eventually("shared Store tables up")` times out after 10s (51 passes, last value `:retry`) and 29 tests fail downstream (`/tmp/azsim_run_4.log`: `73 tests, 29 failures`).
- Mechanism: the test (`test/azsim/plane_supervision_test.exs:22-36`) does `Supervisor.terminate_child(Smalt.Supervisor, DataSupervisor)` then immediately `Supervisor.restart_child/2`. `DataSupervisor` binds a Bandit/ThousandIsland listener on the per-run egress port (`config/test.exs` `test_port.("EGRESS", 8443)`, free-port probe at config load — `lib/smalt/plane/data_supervisor.ex:23,31`). The restart rebinds the same port; when the terminated Bandit's listener socket has not been fully released yet, the new listener gets `:eaddrinuse` and the restart errors. Nothing re-tries, so DataSupervisor stays down and the rest of the shared-subtree batch inherits the dead tables. This happens even solo, so it is a terminate→rebind race, not cross-test interference or load.
- Receipted as-is: a lane with errors must say so. This lane's batch is NOT deterministically green.

## Machine / environment

- macOS Darwin 25.2.0, Elixir 1.19.5, `MIX_BUILD_ROOT=_build-ft-az2`.
- Excluded: 3 amqp_wire-tagged tests (default exclusion), consistent across all runs.

## Cleanup

`_build-ft-az2` removed at end of lane (see lane driver confirmation below); no other files touched besides this receipt.

```
$ rm -rf /Users/sac/smalt/_build-ft-az2
```
