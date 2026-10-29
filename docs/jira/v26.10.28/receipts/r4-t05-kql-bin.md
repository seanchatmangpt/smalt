# r4 — T-05 increment 1: KQL bin() shipped + latent parse_by crash fixed

- window: v26.10.28 · ticket: `tickets/T05-kql-extended-operators.md` (1 of 4 operators) · date: 2026-10-28
- tier: beam (`test/integration/kql_bin_test.exs`)

## what landed

1. **`by bin(Col, <timespan>|<number>)`** in `Smalt.DataPlane.KQL` —
   bucketed summarize group keys. Datetimes (ISO-string or `%DateTime{}`,
   via the engine's `to_datetime/1`) bucket to the bucket-START DateTime;
   numbers floor to step multiples; step validates at parse time
   (timespan `5m`-grammar or numeric). Output column keeps the bare column
   name (Kusto rendering). Composes with plain by-columns and all existing
   aggregates (`count_`, `sum_X`, ...).
2. **Latent crash fixed (found by the malformed-shape courts)**: `parse_by/1`
   returned a bare `{cols, rest}` tuple, so a `key_cols_loop` error
   destructured AS the by-list inside the summarize `with` —
   `parse_stages` FunctionClauseError instead of the typed SYN- error.
   `parse_by` now returns `{:ok, keys, rest} | {:error, _}` (fail-closed
   law actually holds for malformed by-lists).

## court

`test/integration/kql_bin_test.exs` — **7/7 passed**:
5-minute bucketing (2 buckets over a 3-row corpus), composition with
tenantId + sum(), numeric flooring, `%DateTime{}`/ISO equivalence, and
three fail-closed SYN0002 refusals (invalid step `5x`, unterminated,
missing comma).

## regression

integration tier 36/41 — the 5 failures are the pre-existing baseline set;
the 7 new court tests green.
