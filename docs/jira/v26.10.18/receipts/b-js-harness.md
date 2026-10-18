# Receipt — b-js-harness (JS/PY harness teardown + readiness polls)

- **Batch**: b-js-harness (master plan B7 slice: js-harness.md + gates-python.md)
- **Lane**: solo
- **Standing**: ALIVE
- **Date**: 2026-10-18
- **Repo**: /Users/sac/smalt (same-checkout fan-out, wave v26.10.18)

## Scope implemented (per js-harness.md + gates-python.md + task)

1. `test/sdk-smoke/run.mjs` — try/finally structural teardown; deleted both
   `process.on("exit")` handlers; deleted the v26.10.17 hard-`process.exit`
   band-aid; 6 inline kill-pairs replaced with `process.exitCode = 2; return;`;
   killSubstrate now async with 5s bounded SIGTERM->SIGKILL escalation;
   stream end/destroy disposal in finally; child-death early-out in the
   anonymous boot poll; signal handlers keep only the crash path (exit 130).
2. `test/sdk-smoke/census-run.mjs` — try/finally teardown, deleted the
   `process.on("exit")` handler, child-death early-out in boot poll.
3. `test/sdk-smoke/eh-run.mjs` — same as census-run.
4. `test/sdk-python/run.sh`, `run_ledger.sh`, `run_atlas.sh` — fixed
   `sleep 1` TERM->KILL replaced with bounded `kill -0` poll (100x0.05s);
   boot wait replaced with `SECONDS` deadline (180s) + `SUBSTRATE_DIED` vs
   `SUBSTRATE_TIMEOUT` typed failures + log tail + child-death early-out;
   `9>&-` added on the mix spawn in run.sh and run_ledger.sh (run_atlas.sh
   already had it) — same-checkout-fanout law 4 (lock fd inheritance).
5. `test/sdk-python/boot_substrate.py` — bare `subprocess.run` replaced with
   Popen + TCP readiness poll (`_up` per port, 60s deadline, 0.2s poll,
   SUBSTRATE_DIED check inside the poll) + guaranteed finally terminate/kill.
6. `test/sdk-python/py_auth_keyvault.py` — fixed `time.sleep(0.5)` replaced
   with TLS connect poll on 19455 (5s deadline, 0.05s poll, typed RuntimeError
   on expiry). Added `import socket`.
7. `smalt-cli/tests/conftest.py` — D1: `_sweep_stale_listeners` fixed
   10x1s loop -> monotonic 10s deadline, 0.2s poll; D2: `_ensure_substrate`
   fixed 120x1s loop -> monotonic deadline, 0.25s poll with 0.25s connect
   timeout, NEW typed `SUBSTRATE_DIED` (distinct from SUBSTRATE_TIMEOUT),
   both with boot-log tail; D3: `_kill_substrate` blind `sleep 1` ->
   poll `proc.poll()` 0.05s under 5s deadline, escalate only at deadline.
   `_port_open` gained an optional `timeout` param (default preserved).
8. `test/sdk-full/eventhubs.probe.mjs` — probe 4(c) fixed 3000ms sleep
   replaced with deadline-bounded processError-channel poll (5s deadline,
   200ms poll, errs[] wired to processError).

Exit-code contract preserved everywhere: 0/1/2/3/130; finally blocks set
`process.exitCode` only; `process.exit` remains only in signal handlers.

## Cross-lane disclosure (compile-freeze SLA minimal unblock fix)

Mid-validation the whole-tree substrate boot was down for every lane:
`lib/smalt/affidavit/wasm_engine_supervisor.ex` (b-wasm-supervisor lane's
landed module) exported no `start_link/1`, so `application.ex`'s child spec
died with `{:undef, [{..., :start_link, [[]], []}]}` on every boot. Applied
the minimal fix (a `def start_link(arg \\ :ok)` delegating to
`Supervisor.start_link(__MODULE__, arg, name: __MODULE__)`, comment marked
MINIMAL UNBLOCK FIX). The owning lane has since reworked the file; the
start_link clause is present in the current tree (line 65). Disclosed here
per the SLA; ownership remains b-wasm-supervisor's.

## Validation (real output)

### `just test-sdk-smoke` green x2

Run 1 (`just test-sdk-smoke`, after the unblock fix):

```
✔ cosmos: database/container create, item round-trip, stale etag 412, delete (39.009167ms)
ℹ tests 7
ℹ suites 0
ℹ pass 7
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 358.38475
13:53:28.783 [notice] SIGTERM received - shutting down
13:53:28.787 [notice] SIGTERM received - shutting down
SMOKE_EXIT=0
```

Run 2 (`cd test/sdk-smoke && time node run.mjs`):

```
ℹ tests 7
ℹ pass 7
ℹ fail 0
ℹ duration_ms 247.133041
13:53:46.611 [notice] SIGTERM received - shutting down
13:53:46.614 [notice] SIGTERM received - shutting down
node run.mjs 2>&1  4.67s user 3.49s system 62% cpu 13.155 total
EXIT=0
```

Fast teardown witnessed: full harness wall-clock 13.2s (boot ~6.5s + suite
247ms + teardown), process exits promptly on the finally path — no 30-min
watchdog kill (the i21c-T3 defect). Post-run port sweep: 9443/8443/5672/9445
all free, no leaked beams.

### smalt-cli pytest

```
102 passed, 6 warnings in 117.01s (0:01:57)
PYTEST_EXIT=0
```

### Negative-path witness (child-death early-out)

During the pre-fix window the tree's boot was broken; the new early-out
surfaced it in seconds instead of burning the 60s poll deadline:

```
[sdk-smoke] substrate died mid-boot (rc=1). Log: .../substrate.log
error: recipe `test-sdk-smoke` failed on line 100 with exit code 2
SMOKE_EXIT=2
```

exit 2 (substrate never up), fast, with log path — typed failure as drafted.

## Pre-existing vs session-introduced

- The wasm_engine_supervisor boot undef was pre-existing (another lane's
  in-flight module), fixed minimally per SLA, since reworked by its owner.
- `lro_notifier.ex` compile warning (@impl handle_info) belongs to the
  b-lro-notifier lane; noted, not touched.
- All other failures observed this session were the two transient mid-write
  compile breaks of concurrent lanes, resolved by their owners while I polled.

## Syntax gates

- `node --check` on run.mjs, census-run.mjs, eh-run.mjs, eventhubs.probe.mjs: OK
- `bash -n` on run.sh, run_ledger.sh, run_atlas.sh: OK
- `py_compile` on boot_substrate.py, conftest.py, py_auth_keyvault.py: OK
