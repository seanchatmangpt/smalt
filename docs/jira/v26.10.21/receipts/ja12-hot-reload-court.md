# JA-12: Hot-Code-Reload Court (Joe Armstrong doctrine)

**Standing:** **ALIVE** (court PASS, exit 0, reproduced twice consecutively)

- Subject: `test/integration/ja12_hot_reload_court.exs` (repo `/Users/sac/smalt`, branch `main`)
- Toolchain: Erlang/OTP **29** (erts-17.0.5, `/opt/homebrew/opt/erlang@29`), Elixir 1.19.5
- Run: `cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-ja12 PATH=/opt/homebrew/opt/erlang@29/bin:$PATH elixir test/integration/ja12_hot_reload_court.exs`
- Exit: **0** (twice; deterministic)
- Context: solo

## Phases executed (all PASS)

| Phase | Claim verified | Observed |
|---|---|---|
| P1 | `code:load_binary` v1 + gen_server exercise | pid `#PID<0.108.0>`; add(1) x5 → read == 5 |
| P2 | v2 flips behavior without restart | read == 7 (5 + 2×1, doubled, state preserved); pid byte-identical after |
| P5 | Mechanism: dynamic module call vs local call | fq twin: `{1,3}` (parked old frame) → `{2,5}` → `{2,7}` (v2, state preserved). Local twin: `{1,3}`, `{1,4}` — pinned to v1 forever. Purge killed the local twin (non-vacuous negative control) |
| P6 | Purge + delete; process survives on v2 | `check_process_code=false`, `purge=false` (nothing pinned), gen_server alive, pid unchanged, read == 9 (v2 math) after purge+delete+re-register |

## Command output (verbatim, run 2)

```
== JA-12 hot-reload court ==
otp_release=29 erts=17.0.5
[P1] v1 loaded via code:load_binary; gen_server pid=#PID<0.108.0>
[P1] add(1) x5 -> read == 5  PASS
[P2] v2 loaded; add(1) -> read == 7 (doubled, state 5 preserved)
[P2] pid unchanged: #PID<0.108.0> == #PID<0.108.0>  PASS
[P5] both twins on v1: fq replies {1,S}, local replies {1,S}
[P5] fq twin 1st call after v2 load: {1,3} — parked old-code frame (expected)
[P5] fq twin 2nd call: {2,5} — now executing v2 (doubled), state 3 preserved  PASS
[P5] fq twin 3rd call: {2,7} — steady on v2  PASS
[P5] local twin after v2 load: {1,3} — PINNED to v1 (negative control)  PASS
[P5] local twin still v1 after repeated calls  PASS
[P6] fq purge returned false (true = killed a stale old-code holder)
[P6] check_process_code(gen_server, old ja12_gs) = false — gen_server holds no old code
[P6] purge(ja12_gs) = false (false = no process had to be killed; nothing pinned)
[P6] is_loaded(ja12_gs) after purge+delete = false — code server dropped it (in-memory code stays until last reference dies)
[P6] v2 beam re-registered via code:load_binary
[P6] purge+delete old code: gen_server alive=true, pid unchanged, read == 9 (v2 math)  PASS
[P6] local twin killed by purge (was on old code) — negative control non-vacuous  PASS
[P6] fq twin alive after purge: true (informational)
== JA-12 COURT: PASS (all phases)
EXIT=0
```

## Findings (OTP 29, measured — correct two stale premises in the task wording)

1. **`?MODULE:loop(...)` is NOT the hot-reload mechanism — it is a LOCAL call.** The
   compiler folds literal `?MODULE:Function(...)` to a local call, so a process tail-calling
   it is pinned to old code exactly like the local-call variant (probe-falsified: a
   `?MODULE:loop` twin stayed `{1,S}` after v2 load). The true mechanism is a **dynamic
   module call** (`M = ?MODULE, M:loop(S)` via a module argument). This is what the court
   proves, with the local-call twin as the negative control.
2. **One-message lag is the real reload semantics.** A process parked in an old-code
   `receive` handles exactly one more message on old code, then the dynamic tail call
   re-enters current code. The court asserts `{1,3}` then `{2,5}` — not a premature `{2,4}`.
3. **`code:delete/1` after purge deletes the CURRENT code** when no old version remains
   (code-server entry dropped; the process survives only until it next needs the module).
   Correct Armstrong shutdown is purge (removes old, kills pinned processes); the court
   re-registers the v2 beam and asserts survival on v2 math.
4. gen_server survives reloads transparently: its loop lives in `gen_server.erl`, which is
   never reloaded, and dispatches `Mod:handle_call` dynamically. Evidenced by
   `check_process_code=false` and `purge=false` (nothing to kill).

## Falsifier (what would have failed the court)

- pid change or state reset on v2 load; v1 math (`read == 6`) after v2; local twin
  picking up v2; fq twin never leaving v1; purge killing the gen_server; local twin
  surviving its purge (vacuous negative control).

## Honesty notes

- No mocks, no doubles: all modules compiled from Erlang source to in-memory beams via
  `compile:file/2 [:binary]` (`compile:string/1` was removed in OTP 29 — file-based
  equivalent used).
- Benign Elixir compile warnings (`:ja12_fq.start/0 is undefined`) — the twins are loaded
  dynamically at runtime; the static analyzer cannot see them.
- No result jsonl emitted (this is a lifecycle court, not a bench lane).
- Pre-existing modified files in `test/integration/` (`ja7_crash_only_court.exs`) are not
  this lane's diff; lane touched only the JA-12 court file and this receipt.
