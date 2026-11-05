# L9r — AoQ VM flags surface (retry of dead L9)

Standing: ALIVE

## Files (staged explicit paths)

- `rel/vm.args.eex` — `+sbt db`, `+sbwt none`, `+hms 2097152` (whole-line
  directives, fail-closed-checked); rationale comments for each flag.
- `lib/smalt/aoq/flags.ex` — `Smalt.Aoq.Flags`: fail-closed `verify!/0`
  (RELEASE_SYS_CONFIG/vm.args or rel/vm.args.eex), `required_flags/0`,
  `check_flags/1`; whole-line comment-stripped flag matching.
- `lib/smalt/aoq/scheduler.ex` — `Smalt.Aoq.Scheduler`: `pin/1` wraps
  `:erlang.process_flag(:scheduler, n)` (returns previous binding,
  spec `non_neg_integer()`), `next_core/0` bounded round-robin over
  `schedulers_online` via persistent_term-cached atomics.
- `test/internal/aoq_vm_flags_test.exs` — Chicago-style, real file reads,
  real temp-copy mutations for fail-closed legs; no mocks.

## Process-level flags (not VM args)

`Smalt.Aoq.Worker` (worker.ex, landed by the concurrent AoQ lane) carries
`message_queue_data: :off_heap` and `max_heap_size: %{size: 2097152, kill:
true, error_logger: true}` spawn opts; `+hms 2097152` in rel/vm.args.eex is
the VM-wide backstop. Not owned by this lane; cited, not staged.

## SLA minimal unblocks (disclosed, not staged)

- `test/support/kv7_oracle.ex` (untracked, L16's in-flight file): trailing
  `end split_on` → `end` — accidental paste, `split_on` had zero references.
  Owner supersedes on landing.
- `lib/smalt/aoq/transport.ex`: no edits by this lane. It was mid-write by
  the concurrent transport lane (undefined `refuse/1`, then a remote-call-in-
  pattern `:erlang.io_list`) — this lane waited (bounded poll, MIX_ENV=test
  compile deadline ~9 min, converged at attempt 7) until the owner landed a
  compiling state. Owner fixed both defects themselves.

## Verification (receipt-cited)

```
MIX_BUILD_ROOT=_build-lane9r mix test test/internal/aoq_vm_flags_test.exs
exit 0 — 7 tests, 7 passed (0.04s), 0 failures, 0 skipped
```

Toolchain pin honored: elixir 1.20.4-otp-29 / erlang 29.1.2 (asdf paths;
Homebrew 1.19.x refused by mix.exs pin).

## Standing vocabulary

ALIVE: test file ran green this session, command + exit cited above.
