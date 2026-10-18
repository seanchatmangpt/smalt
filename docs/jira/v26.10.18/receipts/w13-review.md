# W13 residual review — group 12 (review lane, Context: solo)

Window: v26.10.18. Contract: WORKQUEUE.md group 12
(`/tmp/rewrite-workqueue.json` index 12, 5 files). Doctrine:
`docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md`. Standing: PASS
(1 REWRITTEN, 4 ALREADY-COMPLIANT).

## Verdicts

| file | verdict | citation |
|---|---|---|
| test/amqp/primitive_codec_test.exs | ALREADY-COMPLIANT | zero sleeps/env/timing (greps empty). `async: true` is lawful: pure in-process AMQP primitive encode/decode roundtrips against real `PrimitiveCodec` — no shared ETS, no process starts, no coordination surface for time to substitute for. Final-state asserts on exact wire bytes (`<<0x40>>`, `<<0x56, 0x01>>`) and `{:ok, decoded, <<>>}` roundtrip tuples. |
| test/corpus/head_database_account_names.exs | ALREADY-COMPLIANT | zero sleeps/env/timing. Canonical corpus row: INCIDENT→FIX→FENCE header, `async: false` + `Smalt.Corpus.Helper.ensure_store/0` (post-i22 resilient-clear), real ARM router dispatch via Plug.Test, asserts the closed wire shape (204/404 HEAD with empty bodies, no api-version requirement — KD/tf-plan-probe fence). Lawful invocation is `mix test test/corpus_test.exs` (loader `Code.require_file`s `helper.exs`; standalone per-file run cannot compile — same as w10's receipted finding). Untouched: assertions preserved verbatim. |
| test/enclave_doctor_env_test.exs | REWRITTEN | only defect in the group: hand-rolled `prev_*` + `on_exit` env save/restore — exactly the pattern the canonical `SmaltTest.Env` (foundations §3.3) replaces ("Replaces … the hand-rolled on_exit restores (leak-batch1..5 campaign)"). Test 1 migrated to `SmaltTest.Env.put_restored(lro_retention_ms: 123_456)` (unset-aware restore in on_exit). Test 2's premise is "key ABSENT during the run" — `Env.with/2`/`put_restored/1` cannot express restore-to-unset-when-externally-set, so its delete + prev-aware on_exit restore stays, with a comment naming the exception. All assertions verbatim: `assert Application.get_env(...) == 123_456`, `refute Application.get_env(...)`, both `ets_check["status"] == "PASS"` with the `details:` interpolation. Zero sleeps. |
| test/policy_rbac_test.exs | ALREADY-COMPLIANT | zero sleeps/env mutation/timing bounds (its "env" hits are policy tag fields, not Application env). Structural sync: `async: false`, setup starts real `Store.start_link([])` when down + `Store.clear()` + `Policy.reset_for_test()` — no sleeps to coordinate. Real Router dispatch (`Plug.Test`), asserts on statuses and typed `PolicyViolation` 400s, audit-event listing. Note: this is the module named in FLAKE_LEDGER F8's 401 cluster (12 failures) whose cure was the structural `async: false`/store-wipe fix, not a sleep — it now runs green. |
| test/smalt_graphlaw_validator_test.exs | ALREADY-COMPLIANT | zero sleeps/env mutation. `async: true` is lawful: `Validator.validate_resource/2` is pure in-process (no Store/GenServer/shared ETS — greps for starts are empty). The single `timeout: 10_000` (:798) is a `Task.async_stream` hang-fence over 32 parallel pure validations — structured runtime supervision timeout, not a fixed-sleep coordination (a poll would assert a different law). Asserts on real SHACL verdicts (`{:ok}` x32, mixed valid/invalid separation). |

## Validation — green x2 (MIX_BUILD_ROOT=_build-ft-w13)

All five group files in one run (corpus file via its lawful loader):

```
== ROUND 1 ==
Finished in 2.6 seconds (1.0s async, 1.6s sync)
138 tests, 0 failures (2 excluded)
exit=0
== ROUND 2 ==
Finished in 5.6 seconds (1.3s async, 4.2s sync)
138 tests, 0 failures (2 excluded)
exit=0
```

Edited file standalone, before the group runs (x2):

```
2 tests, 0 failures   (exit=0)   # round 1, 0.6s
2 tests, 0 failures   (exit=0)   # round 2, 0.3s
```

138 tests, 0 failures, both rounds.

## Notes

- No git (per lane contract). One file edited
  (test/enclave_doctor_env_test.exs); all receipted assertions preserved
  verbatim.
- Pre-existing, not session-introduced: standalone
  `mix test test/corpus/head_database_account_names.exs` cannot compile
  (`Smalt.Corpus.Helper` is loader-required by `test/corpus_test.exs`) —
  matches w10-review's receipted finding; the loader invocation is the
  lawful run.
- `_build-ft-w13` lane build root left on disk; coordinator cleanup via
  `just lane-clean` at integration.
