# W10 residual review — group 9 (review lane, Context: solo)

- **Date**: 2026-10-18
- **Lane**: W10 residual review, group 9 of `/tmp/rewrite-workqueue.json` (5 files as queued)
- **Repo**: /Users/sac/smalt (no git actions per contract)
- **Standing**: PASS
- **Doctrine**: `docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md`
- **Foundations treated as landed**: `SmaltTest.AssertEventually.eventually/2`,
  `SmaltTest.Env`, `SmaltTest.Store.resilient_clear/resilient_setup`,
  `SmaltTest.Singleton.start_supervised_singleton!` (`test/support/`).

## Verdicts

| file | verdict | citation |
|---|---|---|
| test/amqp/frame_codec_test.exs | ALREADY-COMPLIANT | zero `Process.sleep`/`:timer.sleep` sites (grep empty). Node-global env swap (`:primitive_codec`) has full save/restore in `setup` + `on_exit` (:242-253, nil-prev → `delete_env` — required form). The four in-test real-codec swaps each restore in an `after` block (:781-783, :971-973, :1017-1019, :1129-1131). `async: false` documented at :1-5 for the node-global env race. `TestPrimitiveCodec` is a hand-written real implementation of the pinned contract (Chicago-legal stand-in, not a mock). |
| test/corpus/blob_container_reput.exs | ALREADY-COMPLIANT | zero sleeps/timing bounds. Synchronous `Smalt.Corpus.Helper.egress/4` Plug calls; asserts on real statuses + typed error codes (201/200/409 ContainerAlreadyExists, 409 ContainerLocked). Uses canonical corpus helper (`ensure_store/0`), no env mutation, no process starts. |
| test/egress_kv_appconfig_test.exs | ALREADY-COMPLIANT | zero sleeps. Canonical `SmaltTest.Lifecycle.ensure_store_up/0` + `Store.clear()` in setup (:10-14); all-synchronous Plug.Test round-trips; asserts on status codes + typed bodies (`WriteConflict`, `MissingIfMatch`, `KvNotFound`). |
| test/ocel_conformance_test.exs | ALREADY-COMPLIANT | zero sleeps; pure typed threshold asserts + one real-sink leg via `OcelNdjson` on a unique-per-run tmp dir with `on_exit` `rm_rf!` (:7-13 — cleanup law). No env mutation, no process ownership. |
| test/smalt_affidavit_wasm_test.exs | FIXED (canonical-helper swap) | defect: local `wait_until/2` poll helper — `Process.sleep(10)` + fixed try-count bound (100) + untyped flunk message — duplicating the canonical `SmaltTest.AssertEventually.eventually/2`. Swapped to `eventually(fn -> if Process.whereis(WasmEngine), do: :retry, else: {:ok, nil} end, observable: "WasmEngine process stopped", deadline_ms: 5_000)`; local helper deleted. Zero sleeps remain (grep count 0). All receipted assertions (352-byte CTRT magic, offset-167 LE u64 tariff round-trip, typed fail-closed, no-crash-loop) preserved verbatim. |

## Edit summary (one file)

`test/smalt_affidavit_wasm_test.exs`:
- added `import SmaltTest.AssertEventually, only: [eventually: 2]`
- setup stop-then-await now polls the real observable (named process gone) on a
  monotonic deadline instead of a 100-try counter
- removed the local `wait_until/2` (10ms sleep, untyped bound)

## Validation — green x2 (MIX_BUILD_ROOT=_build-ft-w10)

Corpus file runs via its canonical loader (`test/corpus_test.exs` requires
`test/corpus/helper.exs`; standalone `mix test test/corpus/blob_container_reput.exs`
cannot resolve `Smalt.Corpus.Helper` — per-file .exs compile, loader is the
lawful invocation):

```
== ROUND 1 ==
25 tests, 0 failures (1 excluded)      # mix test test/corpus_test.exs
73 tests, 0 failures                   # wasm + egress_kv_appconfig + ocel_conformance + frame_codec
== ROUND 2 ==
25 tests, 0 failures (1 excluded)
73 tests, 0 failures
```

All rounds exit 0. Group total: 98 tests / 0 failures per round.

## Notes

- Workqueue said "6 files"; group 9 holds 5 — reviewed all 5 present.
- No register flips, no GAP changes, no commits (contract: no git).
