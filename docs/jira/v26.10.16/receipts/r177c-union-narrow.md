# R177c — KQL union narrow / predicate totality

Standing: PASS

## Scope

KQL predicate-narrowing landing in `lib/smalt/data_plane/kql.ex`:

- `{:neq, col, lit}` no longer returns true on rows missing the column —
  null is not comparable in Kusto, so a missing column fails `!=` just as
  it fails `==`.
- `sort_key/3` keys are uniform `{tag, value}` tuples so number/string
  branches never mix incomparable terms; numeric order applies only when
  every present value parses as a number.
- `contains`/`startswith` are case-INsensitive (real Kusto semantics;
  downcased compare), with the Unicode-folding divergence documented
  in-source as a parked KD-class note.
- `to_str/1` list→charlist silent coercion removed (lists inspect as
  `"[...]"`), SHIM-COURT-visible coercion contract documented.

## Re-run output (docs lane, 2026-10-16, `_build-lane207`)

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/data_plane/kql_test.exs
Finished in 0.07 seconds (0.07s async, 0.00s sync)
23 tests, 0 failures
```
