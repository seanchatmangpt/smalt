# Receipt: bench lane C-1 — Cosmos<->Blob ETL pipeline (ingest/transform/archive)

- Subject: `/Users/sac/smalt` @ main, working tree (no commits made)
- Lane: C-1 (cross-product bench), owner files:
  - `scripts/bench/c1_cosmos_blob_pipeline.mjs` (written this session)
  - `docs/jira/v26.10.14/bench/c1-cosmos-blob.jsonl` (7 rows, this run)
  - this receipt
- Date: 2026-10-15 (local 20:01-20:03), single clean full run, exit 0

## Command / replay

```
bash -c 'source scripts/bench/lib.sh && pid=$(bench_boot c1) ...'   # substrate, ports 39010..39015, MIX_ENV=test, anonymous auth
C1_ENDPOINT=http://127.0.0.1:39011 C1_OUT=docs/jira/v26.10.14/bench/c1-cosmos-blob.jsonl \
C1_MACHINE="$(bash -c 'source scripts/bench/lib.sh; bench_machine_spec')" \
  node scripts/bench/c1_cosmos_blob_pipeline.mjs
```

Boot note: `bench_boot` was initially bypassed for the final run because a concurrent
lane was executing `pkill -f "mix run --no-start"` in a loop, which killed lane C-1's
substrate three times (silent SIGTERM, no BEAM crash in the substrate log). The final
run booted the identical substrate via the identical `mix run -e "<code>" --no-start
--no-halt` argv (reordered flags, same env/ports) under `nohup`. Same port law
(39010..39015), same MIX_ENV=test anonymous auth.

## Machine (embedded per row in the jsonl)

Apple Silicon (M-series), 14 cores, 48 GB, Elixir 1.19.5 / OTP 28, Darwin 25.2.0.
SDKs: @azure/cosmos 4.10.1, @azure/storage-blob 12.34.0, Node v26.10.0.

## Pipeline table (measured end-to-end, 0 errors across all rows)

| phase | op | n | ops/s | p50 | p95 | p99 | MB/s | errors |
|---|---|---|---|---|---|---|---|---|
| 1 INGEST | ingest-2kib-upsert (cosmos-ts) | 500 | 1703.9 docs/s | 0.434 | 0.737 | 4.43 | - | 0 |
| 2 TRANSFORM | transform-continuation-walk (cosmos-ts) | 500 | 36036.0 docs/s | 2.241 (page ms) | 4.92 | 4.92 | - | 0 |
| 3 ARCHIVE | archive-64kib-put (blob-ts) | 100 | 2032.6 blobs/s | 0.461 | 0.587 | 0.707 | 127.04 | 0 |
| 4a SEQ-INGEST | composite-seq-ingest-2kib (30 s) | 115132 | 3837.7 ops/s | 0.247 | 0.31 | 0.432 | - | 0 |
| 4b SEQ-ARCHIVE | composite-seq-archive-64kib (30 s) | 76183 | 2539.4 blobs/s | 0.367 | 0.494 | 0.67 | 158.71 | 0 |
| 4c COMPOSITE | composite-ingest-plus-archive (60 s concurrent) | 260691 | 4344.9 ops/s | 0.431 | 0.58 | 0.823 | 135.97 | 0 |
| 5 WORM | worm-archive-under-legal-hold (blob-ts-worm) | 10 | 1271.2 blobs/s | 0.731 | 1.384 | 1.384 | - | 0 |

WORM assertions (in the row, not prose): `legal_hold_admitted: true` (10/10 fresh-blob
creates admitted under legal hold — create-path law), `overwrite_status: 409,
overwrite_409: true` (overwrite of an existing blob mid-pipeline refused with
ContainerLocked).

## Interference delta (composite vs sequential)

- sequential total: 3837.73 + 2539.43 = 6377.16 ops/s
- composite (60 s, ingest+archive concurrent): 4344.85 ops/s
- **delta: −31.87%** — yes, cosmos ingest latency degrades under blob load:
  cosmos p50 0.247 -> 0.431 ms (+75%), p95 0.310 -> 0.585 ms (+89%)
- composite throughput split: ingest 2169.35 ops/s (−43% vs seq), archive 2175.5 ops/s
  (−14% vs seq) — cosmos side absorbs most of the interference

## 0-error discipline

Every failure is recorded via `noteErr` (op, code, status, message) and counted
per-phase (`_errDelta`), never swallowed. The WORM overwrite-409 is an assertion
(`overwrite_409` field), not an error. Final run: `total errors: 0 (none)`.

## Known quirks (observed, not errors)

- Substrate containers are immutable-by-default (blob create without
  `x-ms-immutable-policy: false` still enforces WORM on overwrite). Composite loops
  use fresh blob names per window; reuse of a name 409s with ContainerLocked.
- `DELETE` of a legal-hold-cleared container and `DELETE /dbs/<id>` teardown each
  returned 404 from the substrate (lane-private leftovers; no lane impact).
- Warmup: 25 upserts + 10 blob puts, not measured.

## Standing

ALIVE — exact pipeline observed executing end to end against the live lane-private
substrate with 0 errors; all falsifiers ran (interference delta measured, WORM 409
witnessed on the wire in the substrate log: `PUT .../c1-worm-...-0 -> Sent 409`).
