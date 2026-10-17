# Receipt — r-lane523: cosmos SQL whitelist → 80/20 AST translator flip

- **Subject:** `/Users/sac/smalt` @ main working tree, lane I4 (lane 523)
- **Standing:** PASS
- **Date:** 2026-10-17
- **Scope:** docs-only lane. The whitelist honesty gate
  (`GAP(cosmos-sql-translator-absent)`) is superseded: an 80/20 SQL AST
  translator, `lib/smalt/cosmos_sql.ex` (626 lines, `Smalt.CosmosSql`:
  `parse/2`, `eval_doc/2`, `eval_docs/2`, `run/3`, tokenizer at
  `cosmos_sql.ex:303`), is wired into the cosmos data plane at
  `lib/smalt/data_plane/cosmos.ex:1356` (`Smalt.CosmosSql.parse(q, ...)` on the
  query POST path) and `cosmos.ex:1438` (`Smalt.CosmosSql.eval_docs(sql, docs)`
  before feed rendering). The whitelist fast path passes `sql = nil`
  (`cosmos.ex:1436`); non-whitelisted queries are parsed and evaluated by the
  AST instead of being refused with 400 `SyntaxError`. Typed 400s are kept for
  the genuinely-unsupported grammar classes (join, udf, aggregate, offset,
  unbound param — fence `test/data_plane/cosmos_sql_test.exs:88`).

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

Both fence tiers are green on the current tree: the AST translator tests
(`test/data_plane/cosmos_sql_test.exs` — evaluator grammar, projection, WHERE
equality/range/AND/OR/NOT, IN/CONTAINS/STARTSWITH/ARRAY_CONTAINS, ORDER BY/LIMIT,
typed 400 grammar classes) and the c3 cosmos compliance court
(`test/compliance/c3_cosmos.exs`) all pass.

## Falsifiable claim

The flip is falsifiable: reverting `cosmos.ex:1356,1438` to the whitelist-only
path (`sql = nil` unconditionally) would make the AST-translator fences in
`test/data_plane/cosmos_sql_test.exs` fail. The typed-400 court remains
non-vacuous (join/udf/aggregate classes still refuse).
