# frozen-duckdb referent census (lane R1, 2026-10-20)

Standing: ALIVE — the referent is real and locally reachable.

## Primary referent

- `/Users/sac/frozen-duckdb` — git workspace (Cargo workspace v2.0.0-dev, repo
  `github.com/seanchatmanpt/frozen-duckdb`); members `crates/frozen-duckdb`,
  `frozen-duckdb-sys`, `frozen-duckdb-builder`, `test-validation`.
- Prebuilt CLI: `crates/frozen-duckdb/src/duckdb/target-lane3/debug/frozen-duckdb-cli`
  (11.5 MB, 2026-10-19); engine pinned DuckDB `v2.0.0-dev88595` @ `b6013f7aa`.
- Supporting: `/Users/sac/frozen-duckdb-prebuilt-v155` (dylib + headers);
  ggen pack `ggen-ecosystem/vendor/ggen-marketplace/packs/frozen-duckdb-pack`;
  RCERT seals `ggen-marketplace/docs/sjira/v26.10.8/seal/RCERT-FROZEN-DUCKDB-26108*.json`.

## Manifesto numbers vs receipts on disk

README "Audited Performance" matches the manifesto verbatim; sources are
`docs/sjira/v2.0.0-dev/receipts/CAMPAIGN-RECEIPT.md` +
`receipts/fleet004.json` — but the OCEL/throughput rows are labeled
**DISPATCH-CITED**, not materialized court JSON.

## Contradicting local measurement (must reconcile before citing)

Git `b7e2e51` (MAX2 lane-final receipt) records **61,599 rows/s** vs the
claimed 12.16M — see `frozen-duckdb-derivation.md` (lane R3) for the
reconciliation: release-profile batched packed-column ingestion vs
debug-profile per-row MAX2 under load. Both real; different subjects.

## Fleet census

`brew` duckdb 1.4.1 system-wide; no duckdb/frozen-duckdb in any mix.lock or
package.json under smalt. The manifesto is unlinked from the smalt repo.

Verdict: a benchmark/derivation lane is Chicago-lawful — measure the local
checkout, never cite DISPATCH-CITED numbers. R3's derivation receipt is the
gate for any claim that survives.
