# WASM-1: OTP-29 WASM Sandbox Port (bridge / pool / worker + stub runner)

**Standing:** **ALIVE** (court-executed on exact subject; wasmtime swap typed, not yet landed)
Context: solo
Date: 2026-10-21
Lane: WASM-1 (writer, OTP-29) · Repo: /Users/sac/smalt · Build root: `_build-wasm1`

## Subject

Ports `docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md` to Elixir in-repo:

| File | Role |
|---|---|
| `lib/smalt/wasm/bridge.ex` | ingress router: focus-node payload + typed predicate frames -> pool checkout -> one eval frame; maps `{sandbox_aborted, _}` / `{gate_timeout, fail_closed}` / `pool_exhausted`; `security_gate_failure/1` -> HTTP 500 `SecurityGateFailure` envelope |
| `lib/smalt/wasm/pool.ex` | 16-worker (config `:smalt, :wasm_pool_size`) `trap_exit` pool; queue checkout/checkin; EXIT-driven crash-only respawn; typed `{:error, :pool_exhausted}` when drained |
| `lib/smalt/wasm/worker.ex` | port driver (`packet: 4` stdio IPC), local 64 MiB ceiling (67,108,864 B) checked before the frame crosses the port, 5s default fail-closed timeout -> `{gate_timeout, :fail_closed}`, os_pid child-tree kill on teardown (no hung-guest orphans) |
| `priv/wasm/stub_runner.exs` | deterministic STUB runner for the wasmtime production path — wasmtime is installed (`/opt/homebrew/bin/wasmtime`) but `graphlaw_duckdb.wasm` does not exist yet; the swap is config (`:wasm_runner_path` / args), not code |
| `test/integration/wasm_sandbox_court.exs` | 6 gates (3 spec + 3 lane) |

## Courts (all real collaborators — real ports, real OS processes, no mocks)

```
$ PATH=$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH \
  MIX_BUILD_ROOT=_build-wasm1 mix test test/integration/wasm_sandbox_court.exs --trace
Finished in 1.7 seconds (0.00s async, 1.7s sync)
Result: 6 passed
EXIT=0

$ ... mix test test/integration/wasm_sandbox_court.exs test/integration/wasm_abi_court_test.exs
Result: 18 passed
EXIT=0
```

1. **Clean eval** -> documented 429 RU refusal envelope (`refusal_envelope` / 429 / `TooManyRequests`).
2. **Memory wall** — 65 MiB payload -> `{:error, {:sandbox_aborted, :memory_wall}}`; pool + node alive (zero BEAM contamination; the oversized frame never crosses the port — the worker enforces the same 64 MiB ceiling as the runtime boundary).
3. **Pool self-heal** — killed worker -> EXIT-driven fresh respawn (bounded poll on `Pool.idle/1`), next eval admits.
4. **pool_exhausted** — all workers checked out -> typed `{:error, :pool_exhausted}`; recovers after checkin.
5. **Fail-closed timeout** — `--hang` guest, 300ms budget -> `{:error, {:gate_timeout, :fail_closed}}`, port+process reaped, pool respawns.
6. **Guest trap containment** — `--crash` runner exit 86 -> `{:error, {:sandbox_aborted, {:exit_status, 86}}}`, worker dead, pool alive.

## Root-cause finding (the load-bearing one)

The stub runner's script stdio device was silently transcoding latin1 bytes to UTF-8:
the packet-4 length prefix `<<211::big-unsigned-integer-size(32)>>` (`0x000000D3`) hit the
wire as `0x000000C3 0x93` — byte `0xD3` re-encoded as the two UTF-8 bytes of U+00D3 —
desynchronizing the BEAM port reader (Jason decode errors, `malformed_frame`,
`queue` corruption downstream). Fix:

```elixir
# priv/wasm/stub_runner.exs
:io.setopts(:standard_io, encoding: :latin1)
```

Any packet-N stdio harness under `elixir script.exs` needs this; worth a rule pin.

## Mechanic notes


- OTP-29 toolchain: asdf `elixir 1.20.4-otp-29` + `erlang 29.1.2` (repo `.tool-versions` pin;
  brew elixir 1.19.5 fails the `~> 1.20` requirement another lane has in mix.exs).
- ExUnit `start_supervised!({Pool, ...})` twice in one test collides on the default child id
  (module name) -> `{:already_started, pid}`; unique `Supervisor.child_spec(..., id:)` required.
- `:queue` pipe hazard: `q |> :queue.in(item)` passes the queue as the ITEM arg — badarg;
  `:queue.in(item, q)` order is load-bearing.
- BEAM pid reuse makes `refute respawn == dead_pid` flaky-by-nature; assert functional respawn
  (checkout + admit) instead.
- `:file.open(0/1, ...)` raises badarg inside `elixir script.exs` (the VM owns the fds) —
  packet-N harnesses must ride the `:standard_io` device with `encoding: :latin1`.
- Worker `kill_os_pid/1` reaps the whole child tree (`pkill -9 -P` then `kill -9`): the stub
  runner is elixir -> erl (two OS processes); killing the wrapper alone orphans the erl VM
  (witnessed three orphaned `--hang` VMs before the fix).

## Verification ladder actually run

* compile (OTP-29, `_build-wasm1`) — clean
* sandbox court 6/6 (twice, incl. once against HEAD after the sibling GWS-7 bridge alignment landed)
* combined 18/18 with `wasm_abi_court_test.exs` (shared modules)
* `scripts/sleep_gate.py`: zero hits on wasm files (the one FAIL is a pre-existing
  unclassified sleep in `test/internal/impl6_process_label_test.exs` — not this lane's file)
* orphan sweep: `pgrep -fl stub_runner.exs` (non-beam) = 0 after the kill-tree fix

## Production path (typed, not yet executed)

Swap `:wasm_runner_path` to wasmtime over `priv/wasm/graphlaw_duckdb.wasm` once the binary is
compiled from graphlaw + frozen-duckdb; same frame protocol, same courts. The stub exercises
the memory wall locally (worker-side ceiling) and via runner trap (exit 86, wasmtime semantics).

## Falsifier

Any court leg failing on a fresh `_build-wasm1` compile of HEAD + this lane's files; or a
stub-runner frame arriving malformed at the worker (the latin1 pin is in the runner, and the
worker rejects malformed frames fail-closed rather than admitting them).
