# Receipt: IMPL-6 — AR-OBS-02 adoption: OTP process labels on substrate actor families

Context: solo

**Standing:** **PASS (court 4/4) / lib sites ALIVE in HEAD (48ad71f)**

Date: 2026-10-21 · Lane: IMPL-6 (OTP-29 lane, writer) · Build root: `_build-impl6` ·
Toolchain: OTP 29.1.2 + Elixir 1.20.4-otp-29 (the `.tool-versions` pin; lane shell
defaulted to a stray OTP 28 via `.erlmcp` PATH — corrected).
Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"otp":"29.1.2","elixir":"1.20.4-otp-29","darwin":"26.2"}`

## Subject

AR-OBS-02 (verified PASS in the OTP-29 probe wave) adopted: `Process.set_label/1` applied
to 6 spawned-actor sites across the AMQP and ARM LRO families. No behavior change: labels
are observability-only, read back via `:erlang.process_info(pid, :label)` and rendered by
Elixir 1.20's `Logger.Translator` as `Process Label:` inside GenServer crash reports.

Label schema: `%{service:, role:, correlation_id:}` where context exists; plain
`%{service:, role:}` where not.

## Diff (all 6 lib sites committed in coordinator checkpoint 48ad71f)

- `/Users/sac/smalt/lib/smalt/messaging/amqp/connection.ex` — `init/1`:
  `Process.set_label(%{service: :amqp, role: :connection, correlation_id: mode})` — mode is `:sb` | `:eh`
- `/Users/sac/smalt/lib/smalt/messaging/amqp/listener.ex` — `init/1`:
  `Process.set_label(%{service: :amqp, role: :listener, correlation_id: name})` — name is `:sb` | `:eh`
- `/Users/sac/smalt/lib/smalt/messaging/amqp/sweeper.ex` — `init/1`:
  `Process.set_label(%{service: :amqp, role: :sweeper})`
- `/Users/sac/smalt/lib/smalt/messaging/amqp/cbs_router.ex` — `init/1`:
  `Process.set_label(%{service: :amqp, role: :cbs_router})`
- `/Users/sac/smalt/lib/smalt/arm_gateway/lro_sweeper.ex` — `init/1`:
  `Process.set_label(%{service: :arm, role: :lro_sweeper})`
- `/Users/sac/smalt/lib/smalt/arm_gateway/lro_notifier.ex` — `init/1` (converted one-liner
  to a block to host the call):
  `Process.set_label(%{service: :arm, role: :lro_notifier})`

Cosmos: `lib/smalt/data_plane/cosmos*.ex` contain no spawned actors (no `Task.start`,
`spawn`, or GenServer) — the partition arbiter / doc-write spawn-point branch of the order
has no referent; documented here instead of inventing a process. CbsRouter was labeled
anyway as an AMQP actor family member (it is started on demand, not at boot).

New file (untracked, lane-owned):

- `/Users/sac/smalt/test/internal/impl6_process_label_test.exs` — Chicago court

## Court (real process exits, real logger pipeline; no mocks, no sleeps)

`MIX_BUILD_ROOT=_build-impl6 mix test test/internal/impl6_process_label_test.exs`
→ `4 passed` (5.0s). Verified twice; final run against HEAD b87092d.

1. **Boot-tree labels** — `Smalt.Amqp.Sweeper`, `Smalt.ArmGateway.LRO.Sweeper`,
   `Smalt.ArmGateway.LRO.Notifier` running under the self-booted app;
   `:erlang.process_info(pid, :label)` equals the expected schema map exactly.
2. **Spawn-site label** — a real `Smalt.Amqp.Connection` started over a real socketpair
   (`gen_tcp` listen on ephemeral port + connect) carries
   `%{service: :amqp, role: :connection, correlation_id: :eh}`.
3. **Crash court (label rides the crash report)** — a test-owned instance of the real
   `Smalt.ArmGateway.LRO.Sweeper` (unlinked, `tick_ms: :manual`) is killed by an unknown
   `GenServer.call` (real FunctionClauseError exit); the captured crash report contains
   `Process Label: %{service: :arm, role: :lro_sweeper}`. Order-fence probe
   (`Logger.error` after DOWN received) proves the report was in the capture buffer.
4. **Schema court** — same crash path asserts the exact label line
   `Process Label: %{service: :arm, role: :lro_sweeper}` (pinning the whole line: an async
   connection-family crash report carrying `correlation_id` can legitimately land in the
   window, so a bare `refute "correlation_id"` is unsound).

### Verbatim court output (final run)

```
$ MIX_BUILD_ROOT=_build-impl6 mix test test/internal/impl6_process_label_test.exs
....
Finished in 5.0 seconds (0.00s async, 5.0s sync)

Result: 4 passed
```

Sample of the load-bearing captured crash report (test 4):

```
[error] GenServer :"Elixir.Smalt.Impl6.ProcessLabelTest.schema_court_sweeper" terminating
** (FunctionClauseError) no function clause matching in Smalt.ArmGateway.LRO.Sweeper.handle_call/3
...
Process Label: %{service: :arm, role: :lro_sweeper}
Last message (from #PID<0.2008.0>): :impl6_unknown_message
State: :manual
```

## Findings during the lane (disclosed)

- **Toolchain drift**: the ambient shell exposed OTP 28.3.1 (`~/.erlmcp`) while the repo
  pins OTP 29.1.2 (`.tool-versions`). First compile crashed on other lanes' in-flight
  OTP-29-only guard experiments (`is_integer/3` / `int_in/3` in blob_storage/cosmos/
  file_share — compile-freeze violations owned by IMPL-4/AR-WIRE-02, fixed by their
  defguardp unblock at 13:08–13:11). After switching to the pinned toolchain those compile
  clean. No smalt-file fixes by this lane; nothing to disclose under the SLA.
- **Crash-report plumbing fact** (load-bearing for future courts): raw `proc_lib` crash
  reports carry `domain: [:otp, :sasl]`; Elixir's primary translator filter (`sasl: false`)
  interacts such that a bare `:logger.add_handler` observer misses them, but
  `ExUnit.CaptureLog` (via the Logger translator) renders them fully **including
  `Process Label:`** (Elixir 1.20 `Logger.Translator` lines 237–247). GenServer-exit courts
  should use capture_log, not raw handlers.
- Prior court iteration asserted `{:DOWN, ..., %RuntimeError{}}` — wrong: `proc_lib`
  wraps the reason as `{exception, stacktrace-ish}` tuple; courts must match `_reason`.

## Falsifier / replay

`MIX_BUILD_ROOT=_build-impl6 mix test test/internal/impl6_process_label_test.exs` on
HEAD ≥ 48ad71f must return `4 passed`; removing any `Process.set_label` line from the six
sites flips tests 1/2 (process_info mismatch) or 3/4 (missing `Process Label:` line).
