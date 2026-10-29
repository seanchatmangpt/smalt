# BK-GRAPHREAP — caller-side reap of `--hang` court doubles

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22, PDT · **Repo**: /Users/sac/smalt
- Closes BK-ZOMB's PREVENTION-DEFERRED item (receipts `bkzombie-census.md` §2/§4,
  `bkgwsp-poll.md`, `bkbmir4-b10-anchor.md`).

## Verdict

The graphlaw/WASM courts that spawn `--hang` runner doubles now reap their own
doubles: after every court run (pass or fail, via `on_exit`), any `--hang` stub
process absent from the run's baseline census is killed by exact PID and the
kill is verified (fail-closed raise on a survivor). Falsifier: three court runs
(sandbox ×1 + real-runner ×2) with the fix landed show census 51 → 51 → 51 → 51
— zero NEW `--hang` PPID=1 processes. The pre-existing 51 (24 `graphlaw-run
--hang` + 27 `stub_runner.exs --hang` beams) are BK-ZOMBR's drain, not this
lane's; zero touched.

## Leak mechanism (witnessed)

Both hang gates spawn the double with `runner_args: ["--hang"]`:

- `test/integration/wasm_sandbox_court_test.exs` gate 5 (stub runner:
  `elixir priv/wasm/stub_runner.exs --hang` — `Process.sleep(:infinity)`)
- `test/integration/wasm_real_runner_court_test.exs` gate 5 (real
  `graphlaw-run --wasm <snapshot> --expect-blake3 <digest> --hang`)

The double ignores stdio while hung, so when the worker times out fail-closed
and kills the port, the OS process survives, reparents to launchd (PPID=1),
and accumulates one leak per court run — BK-ZOMB census subclass 1.

## Fix

- **`test/internal/hang_reap.exs`** (new): `SmaltTest.Internal.HangReap` —
  `baseline/0` (ps census of `graphlaw-run .*--hang` | `stub_runner.exs
  --hang` PIDs), `reap!/1` (kill -9 by exact PID every census PID not in
  baseline, verifying each kill — raises if a PID survives SIGKILL), `census/0`
  (for the falsifier). Real-collaborator OS census; no mocks.
- Both courts wire it in `setup`:
  `hang_baseline = HangReap.baseline(); on_exit(fn -> HangReap.reap!(hang_baseline) end)`
  — `on_exit` runs pass or fail.

## Falsifier (embedded output)

Pre-fix live census at lane start (baseline): **51 `--hang` processes** (all
PPID=1; 24 `graphlaw-run --hang` + 27 `stub_runner.exs --hang` beam.smp), e.g.:

```
14618  1  graphlaw-run --wasm /Users/sac/.cache/tmp/gws18-wasm-snapshot-1792689234370.wasm --expect-blake3 2ab5cf43... --hang
 1332  1  beam.smp ... -extra /Users/sac/smalt/_build-bkeng0/test/lib/smalt/priv/wasm/stub_runner.exs --hang
```

Post-fix court runs + census (`ps -axo pid=,ppid=,command= | grep -- '--hang'
| grep -v grep | wc -l`):

```
sandbox court   : Result: 6 passed    -> census 51
real-runner x2  : Result: 7 passed x2 -> census 51 (twice)
```

Census flat across every run: zero NEW leaked doubles.

**Non-vacuity witness** (the reap can actually kill; a reap that cannot flip
is a vacuous gate): standalone elixir run of the helper — baseline 51, one
real fresh `graphlaw-run --hang` spawned exactly like the court leak, reap
detected 1 fresh PID, killed `[59502]`, post-reap fresh remaining 0, final
census back to 51.

## Scope / disclosures

- Lane owns: `test/internal/hang_reap.exs`, both `wasm_*_court_test.exs`
  setup blocks, this receipt. Nothing in `lib/` changed — the fail-closed
  timeout path is untouched; this is purely caller-side cleanup.
- The 12+→51 pre-existing leaks predate this lane (the population grew
  during today's wave; BK-ZOMB counted 12 at 08:15). Drain is BK-ZOMBR's
  order, by exact PID, per BK-DUCK tree-aware law; this lane killed none of
  them (baseline-diff design guarantees it).
- Pre-existing (not session-introduced): ash_r2rml compile warnings in the
  test log; unrelated to this diff.
