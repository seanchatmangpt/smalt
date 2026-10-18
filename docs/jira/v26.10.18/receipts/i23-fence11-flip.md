# I23 — Fence-11 shake + FLAKE_LEDGER F6 flip (v26.10.18)

Standing: **ALIVE** (flake reproduced 5/13, typed repair landed, 7/7 green gate; F6 flip grounded on disk)
Subject: `test/affidavit_wasm_failclosed_test.exs` (setup lifecycle helpers) and `docs/jira/v26.10.17/FLAKE_LEDGER.md` row F6
Date: 2026-10-18
Context: solo + 2x `yes` hog load

## Closure 1 — fence-11 shake (B3's flagged flake, test:620 face)

### Shake (pre-fix), MIX_BUILD_ROOT=_build-ft-f11

First shake attempt aborted at the cold compile of the fresh build root
(background time cap). Second attempt hit a sibling lane's in-flight
`test/support/isolation_formatter.ex` (`%ExUnit.RunnerCase` — not a real
ExUnit struct) compile abort 13/13 — compile-abort is not a failure count;
the owning lane repaired it to `ExUnit.TestCase` mid-shake. Third shake on
the repaired tree:

```
=== solo run 1 exit 0 :: 14 tests, 0 failures
=== solo run 2 exit 0 :: 14 tests, 0 failures
=== solo run 3 exit 0 :: 14 tests, 0 failures
=== solo run 4 exit 0 :: 14 tests, 0 failures
=== solo run 5 exit 0 :: 14 tests, 0 failures
=== solo run 6 exit 0 :: 14 tests, 0 failures
=== solo run 7 exit 2 :: 14 tests, 1 failure
=== solo run 8 exit 2 :: 14 tests, 1 failure
=== solo run 9 exit 2 :: 14 tests, 1 failure
=== solo run 10 exit 0 :: 14 tests, 0 failures
SOLO_FAILS=3
=== hog run 1 exit 2 :: 14 tests, 2 failures
=== hog run 2 exit 0 :: 14 tests, 0 failures
=== hog run 3 exit 2 :: 14 tests, 1 failure
TOTAL_FAILS=5/13
```

Full-capture re-run (repro leg, verbatim failure):

```
run 1 exit 0
run 2 exit 2
  1) test fence 5: 16_777_217-byte delta refuses {:error, :payload_too_large} pre-alloc (Smalt.Affidavit.WasmEngineFailClosedTest)
     test/affidavit_wasm_failclosed_test.exs:280
     ** (exit) exited in: GenServer.stop(#PID<0.1642.0>, :normal, :infinity)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.19.5) lib/gen_server.ex:1103: GenServer.stop/3
       test/affidavit_wasm_failclosed_test.exs:37: Smalt.Affidavit.WasmEngineFailClosedTest.stop_engine/0
       test/affidavit_wasm_failclosed_test.exs:116: Smalt.Affidavit.WasmEngineFailClosedTest.__ex_unit_setup_0/1
       test/affidavit_wasm_failclosed_test.exs:1: Smalt.Affidavit.WasmEngineFailClosedTest.__ex_unit__/2
```

Scratch logs: `/tmp/f11_fail_solo_*.log`, `/tmp/f11_fail_hog_*.log`,
`/tmp/f11_full_1.log`, `/tmp/f11_full_2.log`.

### Two faces, one root cause

- **Face A (observed 5/13, setup `stop_engine/0`)**: `GenServer.stop(pid, :normal)`
  on an engine pid the supervisor owner killed/restarted asynchronously
  between `whereis` and the stop → `EXIT noproc` in setup.
- **Face B (the 3/19 `:620` EXIT-killed face)**: hammer load workers called
  `WasmEngine.start_link/1` directly from `Task.async` bodies — a winning
  start LINKS the task to the engine, so the kill-loop's `:kill` propagates
  task→test (`:killed`). Already patched mid-flight by the owning
  wasm-supervisor lane (`Process.flag(:trap_exit, true)` at the top of each
  worker — present in the tree when this lane's shake re-ran). Cited, not
  this lane's diff.

### Repair (this lane's diff, typed bounded deadline)

`test/affidavit_wasm_failclosed_test.exs`, two sites, same class:

- `stop_engine/0`: `GenServer.stop(pid, :normal)` →
  `try GenServer.stop(pid, :normal, 5_000) catch :exit, {:noproc, _} -> :ok end`
  with the supervisor-race comment; existing `wait_until` + 25 ms
  SLEEP-CLASS settle unchanged.
- `typed_start/1` `{:error, {:already_started, pid}}` branch: same bounded
  5_000 deadline + `{:noproc, _}` tolerance (the observed pid can be dead by
  the time we stop it).

### Green gate (post-fix)

```
green solo 1 exit 0 :: 14 tests, 0 failures
green solo 2 exit 0 :: 14 tests, 0 failures
green solo 3 exit 0 :: 14 tests, 0 failures
green solo 4 exit 0 :: 14 tests, 0 failures
green solo 5 exit 0 :: 14 tests, 0 failures
green hog 1 exit 0 :: 14 tests, 0 failures
green hog 2 exit 0 :: 14 tests, 0 failures
GREEN_FAILS=0
```

Scratch logs: `/tmp/f11_green_solo_*.log`, `/tmp/f11_green_hog_*.log`.

## Closure 2 — FLAKE_LEDGER F6 flip

`docs/jira/v26.10.17/FLAKE_LEDGER.md` row F6 (`test/amqp/fuzz_test.exs:561`,
atom-flood fence): OPEN-ROTATING → **RETIRED-CONVERTED**. Grounded on disk
before the flip:

- 885c451 (`fix(fences): soak-C closure — error-codes regen, shacl sweep
  timeout, wave receipts`) converted the fence to structural asserts —
  on-disk check: the :561 test no longer carries the atom-count delta bound;
  asserts gate on the wire-key map carrying every key as a binary, never a
  minted atom.
- `receipts/b3-fence10.md` carries the conversion-method receipt.

The ledger's stale-by-default law was honored: cited commit and current
fence body both verified on disk before flipping standing.

## Disclosure (cross-lane)

- `test/support/isolation_formatter.ex` — not edited by this lane; owning
  lane repaired it mid-shake. No unblock fix applied by i23.
- Worker `trap_exit` (face B) — landed by the owning wasm-supervisor lane;
  disclosed here because it closes the 3/19 `:620` face this dispatch asked
  i23 to shake.
- Lane build root `_build-ft-f11` deleted at integration per the cleanup law.

## Falsifiers

- The flake re-appears on a descendant tree: re-open as a new ledger row
  citing this receipt.
- F6's fence regains any atom-count bound without a new receipt: flip
  invalid.
