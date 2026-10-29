# T-05 — KQL: bin(), join, mv-expand, cross-workspace

- status: IN-PROGRESS 2/4 (2026-10-28): bin() CLOSED (r4, 7/7) and join CLOSED (r5, 8/8 - run/3 named-table map, inner/left, ==-column form); mv-expand and cross-workspace remain. Rider: latent parse_by crash fixed.
- window: v26.10.28 · maps-to: Topaz v1.11 "App Insights / Log Analytics — extended KQL" · verdict-at-open: **PARTIAL**
- size: **L** · depends-on: — · parity-leg: KQL/Sentinel court extensions

## current state (evidence)

`lib/smalt/data_plane/kql.ex` parses and evaluates a scalar-dialect KQL —
`ago(<dur>)`, `now()`, `datetime("<iso8601>")` are implemented
(source-verified). The named operators `bin()`, `join`, `mv-expand`, and
cross-workspace query are absent. The Sentinel surface rides this engine
(`sentinel.ex`).

## scope (court-able increments, in this order)

1. `bin(<expr>, <timespan>)` — bucketing scalar used with `summarize`-class
   aggregation contexts the engine already serves.
2. `join kind=inner|left` — two-table join on keys, real result-shape
   (merged columns, right-side prefixing on collision).
3. `mv-expand` — dynamic-array column expansion with the real row
   multiplication semantics.
4. Cross-workspace: the query surface accepts `workspace("<id>")` sources
   and evaluates across the mounted LogAnalytics workspaces.

Each operator lands with parser tests, eval courts against fixed corpora,
and a wire receipt through the KQL/Sentinel plane.

## non-goals

- Full KCSM/Kusto parity (the engine stays a documented dialect; the
  roadmap names four operators, not the language).

## Definition of Done — the Azure developer's view

You point your workbook/log-query tooling (or the Log Analytics SDK/CLI
query path) at smalt and paste the same queries you use in the Azure
portal: `AppRequests | summarize count() by bin(TimeGenerated, 5m)` renders
five-minute buckets; `AppRequests | join kind=inner AppDependencies on
OperationId | take 10` returns merged rows; a query over a dynamic column
with `| mv-expand Properties` explodes one row per array element — the
column schemas and result tables your dashboards bind to look like the
portal's, and a query naming two workspaces returns the union with the
workspace column populated.

## receipts required

Per-operator corpus courts + one end-to-end wire query receipt; a
documented unsupported-operator refusal stays typed (no silent empty
results).
