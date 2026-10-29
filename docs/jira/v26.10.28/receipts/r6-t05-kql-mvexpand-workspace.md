# r6 — T-05 increments 3+4: KQL mv-expand and cross-workspace CLOSED

- window: v26.10.28 · ticket: `tickets/T05-kql-extended-operators.md` (increments 3 and 4 of 4) · date: 2026-10-28
- tier: beam (`test/integration/kql_mv_expand_test.exs` — two modules, 10 tests)

## increment 3: mv-expand

`| mv-expand <Col> [, <Col>]*` — element-wise list expansion (Kusto
semantics, NOT cartesian): each listed column's LIST value expands one row
per element (zip across listed columns; shorter lists pad nil); non-list
values are singletons; other columns duplicated per element. The hyphenated
operator name lexes as `word "mv" op "-" word "expand"` (the lexer has no
hyphenated words — clause pattern-matches that triple).

## increment 4: cross-workspace sources

`workspace("<id>")[.Table] [, workspace(...)]*` before the first pipe —
eval unions each named source's rows (from run/3's tables map, the join
machinery's map) stamped with a `"Workspace"` column carrying the workspace
id; `.Table` suffix resolves key `"id.Table"` (the lexer folds `.` into
the following word — matched accordingly). Missing workspace = typed
`{:error, {:eval, _}}`; sources not followed by `|` = SYN0002;
no leading workspace clause = fully backward compatible (run/2 unchanged).

parse/1 now returns `{:ok, stages, sources}` (internal shape; run/2/3
public contracts unchanged).

## court

`KqlMvExpandTest` (5): single-column expansion, zip semantics, downstream
summarize, no-column refusal, string-literal refusal.
`KqlWorkspaceTest` (5): two-workspace union + Workspace column, `.Table`
key resolution, missing-workspace eval error, fail-closed pipe requirement,
backward compatibility. **10/10 passed; full KQL court set 25/25**
(bin 7 + join 8 + this 10).

## T-05 final status

All four operators CLOSED: bin (r4), join (r5), mv-expand + cross-workspace
(this receipt). Ticket stamped CLOSED 4/4.
