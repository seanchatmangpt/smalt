# i21 — ETS race fix verification hammer (bench-runner lane)

**Standing**: ALIVE — 5/5 pair runs green, trio green, zero failures across all runs.

## Subject

- Repo: /Users/sac/smalt (main, working tree as of 2026-10-17 ~21:15 PDT)
- Fix receipt awaited and confirmed: `docs/jira/v26.10.17/receipts/i21-ets-race-fix.md` (landed 20:46 PDT, poll try 10 of 15)
- Build root: `MIX_BUILD_ROOT=_build-ft-vets`
- No repo edits, no git operations by this lane.

## Protocol and results

**Pair, 5x alternating argument order** — `MIX_BUILD_ROOT=_build-ft-vets mix test <order>`:

```
RUN 1 exit=0 order=[test/egress_dispatch_test.exs test/eventgrid_topics_arm_test.exs] => 116 tests, 0 failures
RUN 2 exit=0 order=[test/eventgrid_topics_arm_test.exs test/egress_dispatch_test.exs] => 116 tests, 0 failures
RUN 3 exit=0 order=[test/egress_dispatch_test.exs test/eventgrid_topics_arm_test.exs] => 116 tests, 0 failures
RUN 4 exit=0 order=[test/eventgrid_topics_arm_test.exs test/egress_dispatch_test.exs] => 116 tests, 0 failures
RUN 5 exit=0 order=[test/egress_dispatch_test.exs test/eventgrid_topics_arm_test.exs] => 116 tests, 0 failures
```

**Trio** — `MIX_BUILD_ROOT=_build-ft-vets mix test test/egress_dispatch_test.exs test/eventgrid_topics_arm_test.exs test/compliance_test.exs`:

```
TRIO exit=0 => 273 tests, 0 failures (16 excluded)
```

## Environment repair disclosure (compile-freeze SLA, no repo edit)

At run time the tree-wide dep check failed for every build root: the untracked hex
checkout `deps/ash_ex4pm/mix.exs` (checksums match mix.lock outer 11d24b18) pins
`{:ex4pm, "== 26.10.1"}` while root `mix.exs` requires `~> 26.10.8` — unsatisfiable,
so `mix test` refused in every build root including the default. No owner lane resolved
it within the 10-minute SLA window. This lane applied a minimal unblock: sha256 snapshot
(`ea377ffa3709bef885136b00300ec7c7a61407b1c8a48c82b8228eadac58c14c`) -> pin bumped to
`~> 26.10.8` -> all runs executed -> restore byte-exact -> `sha256sum -c` verified OK.
Tracked files, git state, and other lanes' in-flight files untouched. Fresh build roots
will hit the same unsatisfiable dep conflict until an owner resolves it at the
mix.exs/mix.lock level (tracked-file fix is outside this lane's authority).

## Verdict

The historic failing context (egress + eventgrid pair) is green 5/5 under argument-order
alternation; compliance trio 273/0. The ETS race fix holds under hammering.

## Files

- Receipt: /Users/sac/smalt/docs/jira/v26.10.17/receipts/i21-ets-hammer.md
- Scratch logs: /tmp/i21-vets-pair-{1..5}.log, /tmp/i21-vets-trio.log
