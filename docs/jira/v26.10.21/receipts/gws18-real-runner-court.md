# GWS-18: real graphlaw-run adapter + real-wasm sandbox court

**Standing:** **ALIVE** (all deliverables executed on the exact subjects; 7/7 real-runner court green, stub court and ABI court regression green)

Date: 2026-10-21
Lane: GWS-18 (writer, both repos)
Repos: /Users/sac/graphlaw (runner), /Users/sac/smalt (config + court)

## What landed

**graphlaw repo:**

- `src/bin/graphlaw_run.rs` — the real runner: a wasmi host
  (exact `Host`/`request_bytes` pattern of graphlaw `tests/wasm_abi.rs`:
  `gl_alloc`/`gl_call`/`gl_free` over linear memory, WASI p1 imports only,
  `_initialize` called once) wrapped in a packet-4 stdio loop speaking smalt's
  stub-runner protocol. Frames are auto-detected: the smalt eval envelope
  (`{"op":"eval","payload_b64":...,"predicate_frames":[...]}`) decodes the
  payload and runs the REAL graphlaw ABI (`parse`/`canonical`/`law`/`policy`/
  `shacl`/... 14-op surface via `graphlaw::abi`) inside the compiled module;
  non-eval frames pass through as raw ABI requests under the same
  `{"ok":true,"result":...}` envelope. `--crash`/`--hang` fault modes
  preserved with stub-compatible exit codes (86 trap, 90/91/93/94 harness
  faults, 84 digest-mismatch refusal). Predicate frames are a smalt transport
  classification with no ABI analogue; the count is echoed as
  `predicate_frames_count` metadata.
- `Cargo.toml` — optional target-scoped `wasmi`/`wasmi_wasi` deps +
  `runner` feature + `[[bin]] graphlaw-run` (required-features ["runner"]);
  default/wasm32 builds untouched.

**smalt repo:**

- `config/config.exs` — documented config-only swap: `:wasm_runner_path` ->
  the graphlaw-run program+args list (WASM-1's swap contract; stub remains
  the default).
- `test/integration/wasm_real_runner_court.exs` — 7-gate court against the
  REAL runner + REAL pinned artifact (per-run immutable snapshot):
  gate 1 real parse admits (`quads:1`, `id`), gate 1b typed ABI refusal
  (`EngineRejected`/`PurRdf`) with worker survival, gate 1c raw ABI
  passthrough (`capabilities`, `abi==1`), gate 2 65 MiB memory wall with BEAM
  survival, gate 2b pin non-vacuity (wrong digest -> runner exits 84), gate 3
  crash containment (`exit_status 86` contained to the worker, bounded-poll
  heal, then a REAL frame admitted), gate 5 hung runner refused fail-closed
  with bounded-pool heal.
- `lib/smalt/wasm/bridge.ex` — one clause: raw ABI refusal map (`ok:false`)
  unpacks typed as `{:error, {:abi_refusal, ...}}` (the decode leg of the
  swap). NOTE: bridge.ex was WASM-1r's in-flight file; this clause was
  committed by the coordinator inside 8e4ccbf (GWS-7 checkpoint).
- `lib/smalt/wasm/worker.ex` — **disclosed minimal unblock fix in WASM-1r's
  file** (compile-freeze SLA): `runner_command/2` crashed with function_clause
  on a list-valued `:wasm_runner_path` (`String.ends_with?/2` on a list),
  breaking every worker boot in real-runner mode; now the program+args list
  shape is handled explicitly. (Compile-freeze disclosure: this fix is in
  WASM-1r's owned file; WASM-1r should name it in their receipt.)

## Command receipts (actual output)

Real-runner court (final run, artifact 29b7ac7c...):

```
$ MIX_BUILD_ROOT=_build-lane18 mix test test/integration/wasm_real_runner_court.exs
[GWS-18] real-runner court active: /Users/s/graphlaw/target/release/graphlaw-run
Result: 7 passed        (exit 0)
```

Stub court regression (bridge clause + worker.ex fix in tree):

```
$ MIX_BUILD_ROOT=_build-lane18 mix test test/integration/wasm_sandbox_court.exs
Result: 6 passed        (exit 0)
```

ABI court regression:

```
$ mix test test/integration/wasm_abi_court_test.exs
Result: 12 passed       (exit 0)
```

WASM NIF lifecycle:

```
$ mix test test/internal/wasm_nif_lifecycle_test.exs
Result: 4 passed        (exit 0)
```

Runner vs real module smoke (packet-4, direct speak):

```
caps exit 0 | ok:True abi:1
eval exit 0 | wrapper ok:True | result ok:True quads:1 frames:1
refusal: ok False EngineRejected PurRdf
crash exit: 86, stdout empty | hang: alive, no output | digest mismatch exit: 84
```

## Defects found (session evidence)

1. **worker.ex `runner_command/2` list crash** — config-only swap contract
   was broken (list value = function_clause on every boot). Fixed (disclosed
   above); stub court + ABI court green after.
2. **Artifact pin drift is live**: the graphlaw working-tree artifact was
   rebuilt THREE times mid-session by concurrent lanes (36ed8fd2... ->
   2089e4d0... -> 29b7ac7c..., 6.6 MB). registry/ARTIFACTS.blake3 still pins
   cbc80f07... (26.10.13 state). The coordinator's re-pin is already in
   flight (registry/ARTIFACTS.blake3 shows modified in graphlaw status).
   The court serves a per-run immutable snapshot and prints a loud
   `[WASM-PIN-DRIFT]` report naming both digests instead of failing or
   silently passing; pin non-vacuity is court-enforced via gate 2b.
3. **Stub court gate semantics**: a --crash respawn traps on its next frame
   (probed: RUN2 = `{:sandbox_aborted, {:exit_status, 86}}`) — the earlier
   "respawn admits the next frame" gate asserted a property that only holds
   when the respawn drops fault args (it does not). The current stub-court
   gates 5/6 (single timeout + heal poll; crash containment) match the real
   runner's behavior; my court mirrors them.

## Environment notes (honest)

- Toolchain: Elixir 1.20.4-otp-29 + Erlang 29.1.2 via
  `~/.asdf/installs/...` (homebrew elixir 1.19.5 fails the mix.exs ~> 1.20
  gate); Rust stable (graphlaw rust-toolchain pin), wasmi 2.
- Machine was busy (multiple concurrent lanes; one transient
  ocel_emitter.ex compile-freeze resolved by its owner inside the SLA).
- This is NOT a bench lane; no bench jsonl emitted, no ports held.

## Replay

```
cd /Users/sac/graphlaw && cargo build --release --features runner --bin graphlaw-run
cd /Users/sac/smalt && \
  PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH" \
  MIX_BUILD_ROOT=_build-lane18 mix test test/integration/wasm_real_runner_court.exs
```

Falsifier: any gate of `wasm_real_runner_court.exs` failing against the
current `graphlaw-run` + artifact, or the stub court regressing under the
swap clause.

## Gate re-embed (BK-60, 2026-10-21)

Context: solo

Receipt predated the Context law (CTXFILL lineage): no `Context:` line —
hence NO-CONTEXT. Evidence was already embedded (`Result: 7 passed` etc.).
Fresh subject re-check, 2026-10-21:

```
$ grep -n defmodule test/integration/wasm_real_runner_court.exs | head -1
14:defmodule Smalt.Integration.WasmRealRunnerCourtTest do
$ ls -la /Users/sac/graphlaw/target/release/graphlaw-run
-rwxr-xr-x@ 1 sac  staff  4471792 Oct 21 17:29 /Users/sac/graphlaw/target/release/graphlaw-run
$ shasum -a 256 /Users/sac/graphlaw/target/release/graphlaw-run | cut -c1-16
88dbe897ba74b33f
re-check exit 0
```

Court file and real runner both present on disk (runner rebuilt 17:29 today by
the pin-drift lane; digest prefix recorded for provenance). Standing ALIVE unchanged.
