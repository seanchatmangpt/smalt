# Receipt: w3-review — PARTIAL_ALIVE

Context: solo per-file (5 files, x2 each, per embedded commands)
Standing: PARTIAL_ALIVE — group 2 green x2 under no-sleep doctrine (detail in Standing section)

Date: 2026-10-18 · Lane: W3 residual review · Context: **solo** (no fan-out; single
reviewer + executor, one canonical checkout) · Build root: `_build-ft-w3`

## Scope and contract

Group 2 of `/tmp/rewrite-workqueue.json`: review vs NO-SLEEP-DOCTRINE
(`docs/NO_SLEEP_DOCTRINE.md`), apply canonical helpers where defective, PRESERVE
receipted assertions verbatim. Files:

1. `test/affidavit_ocel_emit_test.exs`
2. `test/arm/kd87_sts_leading_empty_segment_test.exs`
3. `test/data_plane/kql_test.exs`
4. `test/error_codes_doc_test.exs`
5. `test/security/lens5_crash_class_test.exs`
6. `test/store_dets_growth_test.exs`

## Verdicts

| File | Verdict | Note |
|---|---|---|
| affidavit_ocel_emit_test.exs | **REPAIRED** | hand-rolled env save/restore → `SmaltTest.Env.put_restored/1` |
| kd87_sts_leading_empty_segment_test.exs | ALREADY-COMPLIANT | pure Plug.Test, zero sleeps, no env mutation, no Store |
| kql_test.exs | ALREADY-COMPLIANT | pure in-process KQL.run; hostile-fuzz corpus deterministic (seeded `:exsss`); zero sleeps, no shared state |
| error_codes_doc_test.exs | ALREADY-COMPLIANT (test) | fence runs real `gen_error_codes.py --check` subprocess; see drift incident below |
| lens5_crash_class_test.exs | ALREADY-COMPLIANT | typed-refusal courts, real LedgerWriter GenServer, no sleeps; assertion on writer survival is state-based |
| store_dets_growth_test.exs | ALREADY-COMPLIANT | private named ETS table (`:dm_growth_t`, unique), synchronous `DetsMirror.sync/1` calls; no sleeps, ratio-free absolute counts on real DEATS file |

Sleep gate over all six: `[SLEEP-GATE] PASS — 6 files, 0 unclassified Process.sleep`
(exit 0). Zero `Process.sleep` / `:timer.sleep` occurrences in the group (grep + gate
agree). No GAP/KD register changes; no new GAP tokens minted.

## Change made (only file touched)

`test/affidavit_ocel_emit_test.exs` setup: replaced the hand-rolled
`prev = Application.get_env(...); Application.put_env(...); on_exit(restore)` block
with `SmaltTest.Env.put_restored(ocel_dir: dir)` — the canonical leak-batch1 restore
discipline (put-if-non-nil / delete-if-unset). The `File.rm_rf!` on_exit is retained.
All 3 receipted assertions preserved verbatim (line-for-line; only the setup plumbing
changed). The third test's direct `put_env` still restores correctly via the setup-
time prev captured inside `put_restored`.

## Drift incident (pre-existing, not W3's defect)

`test/error_codes_doc_test.exs` failed its first run: `docs/ERROR_CODES.md` was stale
against `lib/smalt/arm_gateway/router.ex` (a concurrent lane editing router.ex moved
`InvalidResourceShape` 3805→3791, `OperationNotFound` 2546→2532,
`SubscriptionNotFound` 2520→2506 without regenerating the generated doc). Lawful fix:
regenerate, never hand-edit. `python3 scripts/gen_error_codes.py` →
`wrote /Users/sac/smalt/docs/ERROR_CODES.md (109 rows)`; re-ran the fence twice after
the lane's mtime settled — green x2.

## Verification (real output, MIX_BUILD_ROOT=_build-ft-w3)

Each touched/reviewed file run green twice:

```
$ MIX_BUILD_ROOT=_build-ft-w3 mix test test/affidavit_ocel_emit_test.exs   # run 1
Finished in 0.09 seconds (0.00s async, 0.09s sync)
3 tests, 0 failures
$ MIX_BUILD_ROOT=_build-ft-w3 mix test test/affidavit_ocel_emit_test.exs   # run 2
Finished in 0.06 seconds (0.00s async, 0.06s sync)
3 tests, 0 failures
$ MIX_BUILD_ROOT=_build-ft-w3 mix test test/arm/kd87_sts_leading_empty_segment_test.exs  # x2
Finished in 0.06/0.09 seconds
2 tests, 0 failures   (both runs)
$ MIX_BUILD_ROOT=_build-ft-w3 mix test test/data_plane/kql_test.exs  # x2
Finished in 0.1 seconds (0.1s async, 0.00s sync)
23 tests, 0 failures  (both runs)
$ MIX_BUILD_ROOT=_build-ft-w3 mix test test/error_codes_doc_test.exs  # after regen, x2
Finished in 0.1 seconds (0.00s async, 0.1s sync)
7 tests, 0 failures   (both runs)
$ MIX_BUILD_ROOT=_build-ft-w3 mix test test/security/lens5_crash_class_test.exs  # x2
Finished in 0.1 seconds (0.1s async, 0.00s sync)
4 tests, 0 failures   (both runs)
$ MIX_BUILD_ROOT=_build-ft-w3 mix test test/store_dets_growth_test.exs  # x2
Finished in 0.1 seconds (0.1s async, 0.00s sync)
2 tests, 0 failures   (both runs)
```

Total: 41 tests, 0 failures across 6 files x2.

## Compile-freeze disclosure

One transient shared-tree compile break during the session:
`lib/smalt/arm_gateway/lro_notifier.ex:164` (untracked, in-flight edit by another
lane) failed macro expansion; it resolved on recompile without any W3 intervention —
no unblock fix applied, nothing to attribute.

## Standing

**Standing**: PARTIAL_ALIVE — group 2 reviewed and green x2 under the no-sleep doctrine; the
error_codes doc drift is regenerated and fenced green at this receipt's time of
writing, but `router.ex` remains under concurrent lane edit (doc may drift again
before window wrap; the fence will catch it).

## Falsifier

A `Process.sleep` reappearing in any of the six files, or an assertion body changing
without its receipt, re-opens this lane. `just sleep-gate` over `test/` and
`just docs-dod-check` are the standing guards.
