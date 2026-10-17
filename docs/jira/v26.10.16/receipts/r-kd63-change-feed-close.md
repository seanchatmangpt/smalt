# Receipt — r-kd63: cosmos change feed close (KD-63)

- **Subject:** `/Users/sac/smalt` @ main working tree, lane I4 (lane 523)
- **Standing:** PASS
- **Date:** 2026-10-17
- **Scope:** docs-only lane. KD-63 ("cosmos change feed absent", stale evidence
  `cosmos.ex:496` — "A-IM never read") is CLOSED: the change feed surface is
  implemented and wired.

## Evidence

- `lib/smalt/data_plane/cosmos.ex:1135` — `change_feed(db, coll, headers \\ %{})`
  implements the incremental feed (LSN/_ts-gated, 200 incremental pages, cursor
  continuation, unchanged-container feed semantics); `do_change_feed/2` at
  `:1145`.
- `lib/smalt/data_plane/cosmos.ex:1244` — `cf_requested?/1` reads the
  `a-im` header (`case header(headers, "a-im")`), superseding the stale KD-63
  row evidence "`A-IM: Incremental feed` never read (cosmos.ex:496)". The
  `list_docs` path routes to `do_change_feed/2` when A-IM is present
  (`cosmos.ex:1232-1233`).
- **W-6 fence tests** — `test/data_plane/cosmos_test.exs:2379`
  `describe "W-6 change feed (A-IM: Incremental feed)"`: incremental pages,
  cursor continuation, unchanged-container behavior, "list_docs without A-IM is
  unchanged (no cursor side effects)", and "A-IM via list_docs routes to the
  change feed" (`:2441`, `a-im` header → incremental feed on the list path).
- **Bench witness** — `docs/jira/v26.10.16/receipts/bench-a1-change-feed-rerun.md`
  (lane a1 change-feed re-run, PASS: baseline 2000 ops p50 31.0 ms p95 311.0 ms
  errors 0; stall row errors 0).

## Fence runs (real output, this session)

```
$ mix test test/data_plane/cosmos_sql_test.exs test/data_plane/cosmos_test.exs
...
143 tests, 0 failures
EXIT:0

$ mix test test/compliance/c3_cosmos.exs
...
28 tests, 0 failures
EXIT:0
```

All W-6 change-feed fences pass inside the 143-test run.

## Falsifiable claim

The close is falsifiable: deleting `cf_requested?/1` from the `list_docs`
route (`cosmos.ex:1232`) or breaking `change_feed/3` cursor gating would fail
the W-6 fences (`cosmos_test.exs:2379` describe block) and the a1 change-feed
bench lane.
