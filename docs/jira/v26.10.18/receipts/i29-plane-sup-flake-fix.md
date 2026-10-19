# i29-plane-sup-flake-fix

- **Date**: 2026-10-19
Context: slice(plane_supervision x10)
- **Standing**: ALIVE
- **Lane file**: `test/azsim/plane_supervision_test.exs` (this lane's only edit)

## Root cause

`test/azsim/plane_supervision_test.exs:36` did a single
`Supervisor.restart_child(Smalt.Supervisor, DataSupervisor)` after
`terminate_child`. The terminated subtree's ThousandIsland egress listener
(Bandit, `test_port.("EGRESS", 8443)` probed port) releases its OS socket
asynchronously; a restart racing the release hits `{:error, :eaddrinuse}`
(1/10 solo, cascades to 29 batch failures while DataSupervisor stays down).

## Fix (test-side bounded poll, no sleeps in lane code)

The production restart path is correct-by-spec — restart races on probed
ephemeral ports are environmental — so the poll rides the test. The restart is
now a `SmaltTest.AssertEventually.eventually/2` bounded poll (deadline 10s,
retryable error precisely `:eaddrinuse`; any other return is a typed immediate
failure carrying the offending value). Sleeping happens only inside the one
audited poll implementation, per the no-sleep doctrine. All original
assertions preserved (`which_children` membership, `arm_port` integer,
ControlSupervisor `whereis`/`alive?`).

## Verify gate (actual output)

```
MIX_BUILD_ROOT=_build-ft-ps1 mix test test/azsim/plane_supervision_test.exs   x10
run 1  exit=0 : 2 tests, 0 failures
run 2  exit=0 : 2 tests, 0 failures
... (all 10 identical)
run 10 exit=0 : 2 tests, 0 failures
```

Full 10/10: runs 1-10 all `exit=0 : 2 tests, 0 failures`
(logs `/tmp/ps_run2_1.log` .. `/tmp/ps_run2_10.log`). Pre-fix flake rate was
1/10 (receipt `docs/jira/v26.10.18/receipts/i29-azsim-regression.md`).

## Disclosures

- **Compile-freeze disclosure (cross-lane)**: during this lane's first
  verification batch, `lib/smalt/plane/integration_supervisor.ex` was edited
  concurrently by another lane (added a `Process.whereis(Smalt.Store)` guard
  so the integration-only plane boots its own Store; full-plane boot re-listed
  Store was failing app boot with `{:error, {:already_started, pid}}` ~5/6 of
  runs in the interim window). That other lane's edit — not this one — fixed
  the separate app-boot flake this lane witnessed mid-session; this lane
  applied no fix to `lib/`. This lane's diff is confined to the test file.
- This lane did not touch `scripts/bench/`, `justfile.d/`, REGISTRY.md, or any
  other lane's result files.
