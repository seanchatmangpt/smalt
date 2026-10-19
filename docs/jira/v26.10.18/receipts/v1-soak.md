# Receipt: v1 soak — 3x full `mix test` on `_build-ft-v1`

Context: full x3 (mix test, stress excluded, _build-ft-v1)
Standing: SUSPECT — tree NOT 3x-green under full context (detail in Standing section)

Date: 2026-10-18 15:22 PDT · HEAD 8b5bb9b0bed1ee2838787f9832cd2d7bee88e04e · Context: full
Lane: bench-runner verification (no edits, no git actions).

## Gate

Poll gate: `b0-foundations.md`, `b1-corpus.md`, `b2-amqp.md` all present in
`docs/jira/v26.10.18/receipts/` before run 1 started (b2 landed ~15:00 PDT).

Pre-run 1 compile abort: `lib/smalt/planes.ex` (untracked, in-flight, mtime
14:59) did not compile — `undefined function known/0` inside
`Smalt.Planes.InvalidPlane.message/1`. Per compile-freeze SLA I polled; the
owner settled the file and `MIX_BUILD_ROOT=_build-ft-v1 mix compile` went
green (~15:05) before any run. Compile-abort attempt: exit 1, 0 tests
executed — recorded, not a test failure.

## Results (3 consecutive full runs, same tree, `MIX_BUILD_ROOT=_build-ft-v1`)

| Run | Log | Exit | Body | ExUnit summary (verbatim) |
|---|---|---|---|---|
| 1 | `/tmp/v1-soak-run1.log` | 2 | 195.0 s (17.9 async / 177.1 sync) | `1 doctest, 7 properties, 2633 tests, 2 failures (90 excluded)` |
| 2 | `/tmp/v1-soak-run2.log` | 2 | 204.3 s (23.2 async / 181.1 sync) | `1 doctest, 7 properties, 2633 tests, 1 failure (90 excluded)` |
| 3 | `/tmp/v1-soak-run3.log` | 2 | 287.5 s (18.3 async / 269.2 sync) | `1 doctest, 7 properties, 2633 tests, 2 failures (90 excluded)` |

Acceptance (3x zero-failure full pass) NOT MET: 3/3 runs RED, 0/3 green.

Count note: 2633 tests vs the 2655 seen at r246 warm-up — stress-tier
drafting this window (`docs/jira/v26.10.18/rewrite-drafts/stress-tier.md`)
may account for the delta; exact provenance of the -22 not verified by this
lane. 90 excluded = `:amqp_wire` default exclusion.

## Failure identities (verbatim, per run)

### Run 1 (2 failures)

```
  1) test fence 10: restart hammer under parallel load — valid starts recover within the retry bound, artifact refusals stay fast (Smalt.Affidavit.WasmEngineFailClosedTest)
     test/affidavit_wasm_failclosed_test.exs:532
     ** (exit) exited in: GenServer.stop(#PID<0.7703.0>, :normal, :infinity)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.19.5) lib/gen_server.ex:1103: GenServer.stop/3
       test/affidavit_wasm_failclosed_test.exs:37: Smalt.Affidavit.WasmEngineFailClosedTest.stop_engine/0
       test/affidavit_wasm_failclosed_test.exs:116: Smalt.Affidavit.WasmEngineFailClosedTest.__ex_unit_setup_0/1

  2) test docs/ERROR_CODES.md is the byte-identical projection of the sources (Smalt.ErrorCodesDocTest)
     test/error_codes_doc_test.exs:46
     docs/ERROR_CODES.md is stale relative to the sources.
     Regenerate: python3 scripts/gen_error_codes.py
```

### Run 2 (1 failure)

```
  1) test docs/ERROR_CODES.md is the byte-identical projection of the sources (Smalt.ErrorCodesDocTest)
     test/error_codes_doc_test.exs:46
     docs/ERROR_CODES.md is stale relative to the sources.
```

### Run 3 (2 failures)

```
  1) test docs/ERROR_CODES.md is the byte-identical projection of the sources (Smalt.ErrorCodesDocTest)
     test/error_codes_doc_test.exs:46
     docs/ERROR_CODES.md is stale relative to the sources.
     Regenerate: python3 scripts/gen_error_codes.py

  2) test list_prefix/2 under concurrent mid-walk deletes: no MatchError, all rows in prefix (Smalt.StoreChurnTest)
     test/store_churn_test.exs:37
     Assertion with > failed, both sides are exactly equal
     code: assert length(values) > 0
     left: 0
     stacktrace:
       test/store_churn_test.exs:42: (test)
```

## Classification vs `docs/jira/v26.10.17/FLAKE_LEDGER.md` + new-batch surfaces

1. **`Smalt.ErrorCodesDocTest` — 3/3 runs.** DETERMINISTIC doc-drift (F15
   class), not jitter. Confirmed live off-test:
   `python3 scripts/gen_error_codes.py --check` fails on the current tree
   (`docs/ERROR_CODES.md is stale`); the diff shows `compliance/c1-arm` rows
   whose HTTP-status column drifted. Neither `test/compliance/c1_arm.exs`
   nor `docs/ERROR_CODES.md` is worktree-modified, so the drift is in
   committed state — a batch lane landed source-side changes without the
   regen. Not a test defect; fix = run `python3 scripts/gen_error_codes.py`
   (regen excluded from this lane's no-edit scope).

2. **`Smalt.StoreChurnTest` (`test/store_churn_test.exs:37`) — 1/3 (run 3).**
   Exact FLAKE_LEDGER **F14** identity: `list_prefix` under concurrent
   mid-walk deletes returns 0 rows; standing OPEN-ROTATING (nonrecurring,
   mechanism UNRESOLVED, last witness i21 post-fix runs). Recurrence count
   for F14: +1. Solo-bisect first per r236 §6 protocol.

3. **`Smalt.Affidavit.WasmEngineFailClosedTest` fence 10 (`:532`) — 1/3
   (run 1).** Same file as ledger row F9 but a DIFFERENT face and mechanism:
   F9 was the 100→250 ms retry-bound assert (`:502`), CLOSED; this is a
   setup-time `GenServer.stop(pid, :normal, :infinity)` exiting "no process"
   from `stop_engine/0` (`:37` → setup `:116`). `test/affidavit_wasm_failclosed_test.exs`
   is worktree-modified by another lane (in-flight batch edits), so this
   face is on the NEW-BATCH surface, with no FLAKE_LEDGER row. Proposed new
   row: fence-10 restart-hammer setup teardown race — engine process already
   dead at setup stop; needs an owner-lane solo bisect on
   `_build-ft-v1`-equivalent quiet tree before a standing is assigned.
   **NEW FACE (unledgered).**

## Standing

**SUSPECT.** The tree is NOT 3x-green under full context: one deterministic
committed doc-drift (ErrorCodes, regen pending), one OPEN-ROTATING ledger
face (F14, 1/3), one unledgered new-batch face (fence-10 setup, 1/3). The
0-failure acceptance for the v1 rewrite is unmet as of this receipt; the
ErrorCodes regen is a one-command fix an authorized lane must land before
the next attempt.

## Cleanup

`_build-ft-v1` NOT deleted: the `rm -rf` was denied by the permission
system and `just lane-clean` (06-lane-cleanup.just) does not register this
root — `DELETED 0 dirs`. Left on disk (~1.5 GB class) for the coordinator
to reclaim (`rm -rf /Users/sac/smalt/_build-ft-v1` at integration).

---

# Addendum: Instance B (`_build-ft-v1b`) — RELAUNCH dispatch, same receipt path

**Standing: SUSPECT — 0/3 consecutive clean.** Separate writer instance, separate
private build root, same dispatch (3x full `mix test`, stress excluded — 0 stress
runs, no edits, no git). Runs executed 15:0x–15:21 PDT while Instance A's suite and
TWO other full-suite `mix test` beams + a ggen semconv replay were concurrently
live on the shared checkout. Machine:
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`.
HEAD moved 29bb037 -> 8b5bb9b mid-run (coordinator commit — explains Instance A's
"committed-state" ErrorCodes observation vs this instance's earlier worktree-modified
`test/compliance/c1_arm.exs`).

## Prescribed runs (all three RED — compile aborts, 0 tests executed)

### Run 1 — COMPILE ABORT

    error: undefined variable "prev_secret"
      │
 1521 │     if prev_secret == nil do
      │        ^^^^^^^^^^^
      │
      └─ test/auth_enforce_test.exs:1521:8: Smalt.AuthEnforceTest."test lens2
         rotation: env secret DELETED between mint and verify -> refused
         (no silent dev-secret fallback)"/1
    (identical second error at 1524:56)
    == Compilation error in file test/auth_enforce_test.exs ==
    ** (CompileError) test/auth_enforce_test.exs: cannot compile module
       Smalt.AuthEnforceTest (errors have been logged)

Mechanism (read from disk): `prev_secret` assigned in the test body (:1502) but
referenced in the `after` block (:1521/:1524) where it is out of scope. In-flight
lane edit (+25/-17), since fixed by its owner.

### Run 2 — byte-identical compile abort (EXIT=1)

    == Compilation error in file test/auth_enforce_test.exs ==

### Run 3 — compile abort, different file (tree moved mid-soak)

    == Compilation error in file test/affidavit_wasm_failclosed_test.exs ==
    ** (CompileError) cannot compile module
       Smalt.Affidavit.WasmEngineFailClosedTest (errors have been logged)

Also since fixed by its owner (+36/-8); compiled cleanly in the diagnostic runs.

## Diagnostic runs 4/5 (beyond prescription; run 5 log: /tmp/v1_soak_run5.log, 175,739 lines)

    Finished in 258.5 seconds (14.9s async, 243.6s sync)
    1 doctest, 7 properties, 2633 tests, 4 failures (90 excluded)

Failure identities (verbatim):

1. `test/store_dets_test.exs:27` — `** (MatchError) no match of right hand side
   value: {:error, {:not_a_dets_file, ~c"/Users/sac/.cache/tmp/smalt_dets_mirror_67586/dm_t_resources.dets"}}`
   at `:dets.open_file(..., repair: false)`; stack `test/store_dets_test.exs:38`.
2. `test/affidavit_wasm_failclosed_test.exs:640` — fence 11 supervised-restart
   hammer: `** (EXIT from #PID<0.107002.0>) :kill`.
3. `test/error_codes_doc_test.exs:46` — `docs/ERROR_CODES.md is stale relative to
   the sources. Regenerate: python3 scripts/gen_error_codes.py` (the six
   `compliance/c1-arm` rows). Confirms Instance A's 3/3 deterministic face.
4. `test/semantic_epoch_test.exs:323` — `10k unique parse vs raw decode control:
   ratio 89.56 >= max 15.0` / `subject_us 941674 / baseline_us 10514`
   / `A 10x subject-op slowdown must fail this assertion (AZB-12 anti-vacuity).`

## Classification (Instance B faces)

| Face | Ledger row | Classification |
|---|---|---|
| store_dets `:not_a_dets_file` | F12 = same file, different mechanism (churn timeout, CLOSED) | NEW FACE — per-run mirror dir under ~/.cache/tmp; cross-lane tmp contention suspect (unproven, machine shared with 2 live full-suite beams + ggen replay) |
| fence 11 hammer `EXIT :kill` (:640) | F9 = fence 10 (:502), CLOSED | NEW FACE, b-wasm-supervisor surface — that surface's receipt itself documents kill-loop load sensitivity; load-class suspect, needs solo bisect |
| ERROR_CODES.md stale | n/a | NOT A FLAKE — deterministic generated-doc drift; one-command fix `python3 scripts/gen_error_codes.py`; blocks any 3-clean acceptance until regenerated |
| semantic_epoch perf ratio 89.56 vs max 15 | not in ledger | NEW FACE, perf-budget class — 6x over bound under heavy concurrent load; solo re-run required to split load artifact vs real regression |

## Cleanup (Instance B)

`rm -rf /Users/sac/smalt/_build-ft-v1b` REFUSED by the permission system (direct
and via `just lane-clean <arg>`, which takes no argument; tree-wide `just lane-clean`
not run from a lane). **BLOCKED: `/Users/sac/smalt/_build-ft-v1b` (697 MB) remains
on disk** — coordinator reclaim via `just lane-clean` at integration
(skips live-referenced roots).
