# IMPL-26 / AR-OBS-02 — Remaining spawn-site process-label adoption

Context: solo

- **Repo**: /Users/sac/smalt (canonical checkout, lane build root `_build-impl26`)
- **Date**: 2026-10-21
**Standing**: ALIVE (court 6/6 green, regression pass green, diff landed at HEAD 8defcf5)

## Context

IMPL-6 labeled 4 actor families (AMQP sweeper/cbs_router/listener/connection,
ARM LRO sweeper/notifier). This lane completed AR-OBS-02 adoption: census of the
remaining spawned-process sites in `lib/smalt` (spawn/spawn_link/Task.start), labeling the
top unlabelled families under the IMPL-6 schema `%{service:, role:, id:}`.

## Census result (grep over lib/smalt, test/ excluded)

| Site | Family | Action |
|---|---|---|
| `lib/smalt/apim.ex:49` (spawn_link) | APIM rate-table owner | **LABELED** `%{service: :apim, role: :rate_table_owner}` |
| `lib/smalt/hw/virtual_serial.ex:162` (Task.start, stdio reader) | hw serial readers | **LABELED** `%{service: :hw, role: :serial_reader, id: :stdio}` |
| `lib/smalt/hw/virtual_serial.ex:189` (Task.start, file reader) | hw serial readers | **LABELED** `%{service: :hw, role: :serial_reader, id: path}` |
| `lib/smalt/powl2/executor.ex:184` (Task.async frontier wave) | POwL2 frontier eval | **LABELED** `%{service: :powl2, role: :frontier_eval, id: Map.get(node, :id)}` |
| `lib/smalt/messaging/amqp/listener.ex:161` (DynamicSupervisor.start_child) | AMQP connection children | Already labeled — `Smalt.Amqp.Connection.init/1` calls `Process.set_label(%{service: :amqp, role: :connection, correlation_id: mode})` in the child; no new site needed |

Negative census (asked-for families with no spawn sites):
- blob/cosmos per-request handlers: none — requests are served on Bandit request
  processes; no `spawn`/`Task.start` in `lib/smalt/data_plane/`.
- event_grid subscriber dispatch pids: none — `lib/smalt/event_grid_webhook.ex` contains
  no spawn.

4 new labeled sites (within the ≤12 limit).

## Court

Extended `test/internal/impl6_process_label_test.exs` with a describe block `IMPL-26`.

Real output:

```
$ MIX_BUILD_ROOT=_build-impl26 mix test test/internal/impl6_process_label_test.exs
......
Finished in 5.0 seconds (0.00s async, 5.0s sync)
Result: 6 passed
```

6/6 green (4 pre-existing IMPL-6 + 2 new IMPL-26):
- labeled vs unlabeled spawn over real `spawn/1`: labeled shows
  `{:label, %{service: :court, role: :labeled_probe}}`; unlabeled shows `{:label, :undefined}`
  (the info item always exists on OTP 29; the VALUE is `:undefined` when unset).
- APIM rate-table owner label visible via `:erlang.process_info(pid, :label)` on the real
  spawn_link'd owner (published via persistent_term; Smalt.Apim has no registered name).
- Crash-report rendering documented: already proven by IMPL-6 (test "crash report of a
  labeled actor carries the label (proc_lib -> Logger)"): a real labeled
  `Smalt.ArmGateway.LRO.Sweeper` crash emits
  `Process Label: %{service: :arm, role: :lro_sweeper}` through the Logger pipeline from the
  dying process, asserted byte-exact in the IMPL-6 court, unchanged and still green.
- Bounded-poll on the labeled probe (label is set concurrently with the spawn; observed
  within budget, no fixed sleep — no-sleep doctrine).
- OTP 29 toolchain: erlang 29.1.2 + elixir 1.20.2-otp-29. Note: 1.20.4-otp-29 fails
  compiling `lib/smalt/data_plane/key_vault_actions.ex` with misplaced-pin errors —
  pre-existing toolchain interaction, not session-introduced.

## Regression pass

```
$ MIX_BUILD_ROOT=_build-impl26 mix test test/internal/powl2_executor_test.exs test/apim_policy_test.exs
Result: 11 passed, 0 failures
```

## Diff

4 lib files + 1 test file (4 `Process.set_label` sites + poll-based court extension).
Note: the coordinator's tick-checkpoint commit (8defcf5) landed this lane's working-tree
edits mid-flight; content verified present at HEAD (`git show HEAD:lib/smalt/apim.ex`
shows line 50 set_label; `git show HEAD:test/internal/impl6_process_label_test.exs`
contains the IMPL-26 block).
