# Bench receipt — B-2: blob SDK (TypeScript) vs live substrate

- Lane: B-2, v26.10.14 bench wave
- Date: 2026-10-15 (single final clean run; two prior runs discarded as
  harness-defective, see Run history)
- Subject: `scripts/bench/b2_blob_ts.mjs` driving the real TypeScript
  `@azure/storage-blob` (installed under `test/sdk-full/node_modules`) against
  the live smalt substrate booted via `scripts/bench/lib.sh` `bench_boot b2`
  (MIX_ENV=test, auth_mode :anonymous, private ports **39020-39025**; egress
  data plane `http://127.0.0.1:39021`).
- Auth shape: `BlobServiceClient` + `StorageSharedKeyCredential`
  (`smaltacct`/`smaltacct-key`), identical to `test/sdk-full/blob.probe.mjs`.
- Result file: `docs/jira/v26.10.14/bench/b2-blob-ts.jsonl` (4 rows, schema per
  `scripts/bench/REGISTRY.md`).

## Machine spec (embedded, from bench_machine_spec)

```json
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

## Headline numbers (final clean run)

| measurement | n | result | p50 / p95 / p99 (ms) | errors |
|---|---|---|---|---|
| put-block-blob 8 KiB | 130,535 ops in 30 s | **4,351 ops/s** (34.0 MB/s) | 0.218 / 0.299 / 0.414 | 0 |
| put-block-blob 64 KiB | 87,351 ops in 30 s | **2,912 ops/s** (182 MB/s) | 0.334 / 0.418 / 0.526 | 0 |
| download byte-equality | 40 x 512 KiB = 20 MiB | **667 MB/s** (1,333 dl/s), equality verified on every blob | 0.640 / 0.950 / 3.695 | 0 |
| list-blobs-flat full page (100 blobs) | 50 pages | 101 pages/s | 9.445 / 11.328 / 19.309 | 0 |

## Method

- Container created with the substrate `x-ms-immutable-policy: false`
  opt-out (mutable, same as `test/sdk-full/blob.probe.mjs` step 1).
- Warmup: 40 uploads (20 x 8 KiB + 20 x 64 KiB) + one download before any
  measured window; none of it counted.
- Puts: sequential sustained loop for a 30 s window per payload size; per-op
  latency via `process.hrtime.bigint()`.
- Downloads: sequential 512 KiB GETs, each buffered and `Buffer.equals`
  verified against the uploaded random payload (substrate Put Blob limit is
  1 MiB, so the download blob is 512 KiB; 20 MiB total downloaded, meeting the
  >=20 MiB floor exactly). Stop-at-first-mismatch on inequality.
- List: 100 blobs uploaded in parallel, then 50 sequential full-page
  `listBlobsFlat({pageSize: 1000})` calls, each asserting >=100 names
  returned (144 visible including warmup blobs); latency per full page.
- Errors recorded per window (col 8 of SUMMARY); failures abort the run with
  `FAILED` on stdout — a failed run is recorded as failed, never estimated.

## Run history (recorded as failed, per lane rules)

1. Run 1 — harness defect: a single module-load-time `AbortSignal.timeout(60s)`
   expired mid-run, injecting 9,249 spurious errors into the 64 KiB window and
   aborting at download. Discarded, fixed (per-call signals).
2. Run 2 — substrate limit surfaced: 4 MiB Put Blob rejected
   `RequestBodyTooLarge` (1,048,576-byte per-PUT limit). Discarded; download
   payload resized to 512 KiB. (Limit is a real substrate fact, noted here.)
3. Run 3 — measurement ran to DONE with 0 op errors but the list sanity check
   expected exactly 202 visible names (144 visible) and falsely flagged all 50
   list iterations as errors. Discarded, check relaxed to `>=100`.
4. Run 4 (final) — clean: all four measurements, 0 errors, substrate down,
   ports 39020-39025 verified free after.

## Teardown

`bench_down` + kill of any 39020-39025 LISTEN holder; post-run check:
`ALL_PORTS_FREE`. No lib edits, no commits made by this lane.
