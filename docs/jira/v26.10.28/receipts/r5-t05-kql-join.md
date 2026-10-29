# r5 — T-05 increment 2: KQL join shipped

- window: v26.10.28 · ticket: `tickets/T05-kql-extended-operators.md` (2 of 4 operators) · date: 2026-10-28
- tier: beam (`test/integration/kql_join_test.exs`)

## what landed

`| join [kind=inner|innerunique|left|leftouter] <Table> on <Col>[ == <Col>]`
in `Smalt.DataPlane.KQL`, with a new `run/3` arity threading a named-table
map (`%{name => rows}`) — pipeline rows are `$left`, `tables[<Table>]` is
`$right`. `run/2` delegates to `run/3` with an empty map (all existing
callers unchanged).

Semantics (documented divergences honest):

- kinds: `inner`/`innerunique` → inner; `left`/`leftouter` → left-outer
  (unmatched left rows kept verbatim, appended after the matches).
- collision policy: right value wins under the bare column name; the left
  value survives under `<Col>_left` (Kusto drops it from the merged column
  — this engine keeps it losslessly).
- join keys normalize datetimes (ISO-string or `%DateTime{}`) so temporal
  keys match across the two tables' storage shapes; everything else
  compares raw.
- a `<Table>` missing from run/3's map is a typed `{:error, {:eval, msg}}`
  (run_err union widened with `:eval`); malformed join shapes refuse
  SYN0002 (parse time), including through the parse_by fix from r4.

## court

`test/integration/kql_join_test.exs` — **8/8 passed**: the ticket's DoD
shape (`AppRequests | join kind=inner AppDependencies on OperationId`),
collision `_left` survival, left-outer retention, explicit `==`-column
form, ISO↔DateTime key equivalence, downstream summarize composition,
default-kind inner, missing-table eval error, malformed-shape SYN0002.

## regression

integration tier 44/49 — the 5 failures are the pre-existing baseline set;
bin court still 7/7.
