# BK-SQLD2X — sqld2 script court → ExUnit case (GWSSKEP2 vacuous-pass hazard closed)

Standing: **ALIVE** · Context: solo · 2026-10-22

## What

`test/integration/sqld2_sql_ingest_court.exs` was a self-running script
(`elixir ...` / `mix run --no-start`). Under `mix test` it reported "0 tests",
exit 0 — a typed vacuous pass for census tooling (GWSSKEP2 hazard). Converted
to an ExUnit case via `git mv` to `test/integration/sqld2_sql_ingest_court_test.exs`
(BK-POWLH4 pattern, ath3/gld7/graphlaw_dual_governance precedent): court legs
untouched, tail runner (`Code.compile_file` + `Sqld2.Court.run()`) replaced by
an `ExUnit.Case` asserting `Sqld2.Court.run()`.

Diff to the court body: **zero**. Only the header Run line, the tail, and the
added conversion comment.

## Before

```
$ MIX_BUILD_ROOT=_build-bkgwsskep2 mix run --no-start test/integration/sqld2_sql_ingest_court.exs
... legs 1–6 green ... SQLD2 COURT: PASS
$ MIX_BUILD_ROOT=... mix test test/integration/sqld2_sql_ingest_court.exs
0 failures   # "0 tests" — silent drop, exit 0
```

(Second line reproduced by GWSSKEP2, `bkgwsskep2-wave-verify.md` line 40.)

## After

```
$ PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-bksqld2x mix test test/integration/sqld2_sql_ingest_court_test.exs
leg1 scanner: read_pg_copy refused as expected -> typed fallback ...
leg6 SHACL gate: injection-token table refused ...
SQLD2 COURT: PASS
dump sha256: c5c65bd153391752d05a56b3d9311a0492d90f21e44da4d28a82637afeed1990
rows: 500 (customers 120 / orders 300 / order_events 80)
ocel: 80 events / 420 objects / 380 rels
excursion orders: 11
Finished in 0.4 seconds
Result: 1 passed
```

In-batch: `mix test test/integration` → **233 tests, 233 passed** (sqld2 legs
1–6 executed in-batch, log lines 1882–1891; up from 232 — the previously
dropped file now adds 1 test).

Run note: first in-batch attempt (under concurrent lane load) showed 2 failures
in other suites; clean re-run 233/233. Sqld2 green in both runs; not this
change's defect (pre-existing load sensitivity elsewhere, disclosed).

## Census registration

No census/manifest file registers the old path by name (checked
`scripts/audit_surface_census.sh`, `justfile.d/`, `_LANES.md`, budget manifest
-- sqld2 had no budget entry since it never ran under mix test). Only
historical receipts reference the old name; left as-is. The test-budget gate
will now see 1 new unbudgeted test at next `just test-budget-seed` — expected,
flagged here.

## Successor note

GWSSKEP2 typed hazard updated in
`docs/jira/v26.10.22/receipts/bkgwsskep2-wave-verify.md` (one-line addendum,
owned by this lane).

## Files

- `test/integration/sqld2_sql_ingest_court_test.exs` (renamed + converted)
- `docs/jira/v26.10.22/receipts/bkgwsskep2-wave-verify.md` (addendum)
- `docs/jira/v26.10.22/receipts/bksqld2x-convert.md` (this receipt)
