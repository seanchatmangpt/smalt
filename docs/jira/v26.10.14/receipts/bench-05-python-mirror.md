# Bench B-5 — Python SDK parity numbers (blob + cosmos)

- lane: b5
- date: 2026-10-15
- subject: `scripts/bench/b5_python_mirror.py` under `test/sdk-python/.venv-blob`
  (azure-storage-blob 12.31.0, Python 3.14.3) and `.venv-cosmos`
  (azure-cosmos 4.17.1, Python 3.14.3) against a private smalt substrate
  (`scripts/bench/lib.sh` `bench_boot b5`, MIX_ENV=test, anonymous auth,
  egress plane 127.0.0.1:39051, port block 39050-39055).
- results: `docs/jira/v26.10.14/bench/b5-python-mirror.jsonl` (4 records, errors=0 on all)
- machine: Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5 / OTP 28, Darwin 26.2

## Measures (mirroring B-2/B-3)

| measure | n | result |
|---|---|---|
| blob put-block-blob 8 KiB sustained | 9,172 ops / 10 s | 917.2 ops/s — p50 1.054 ms, p95 1.334 ms, p99 1.570 ms |
| blob download (1 MiB blob) | 20 iters | 744.2 MiB/s — p50 1.338 ms, p95 1.431 ms, p99 1.561 ms |
| cosmos point read | 500 reads | 294.7 ops/s — p50 3.225 ms, p95 4.208 ms, p99 6.008 ms |
| cosmos `SELECT * FROM c` (1000 docs) | 5 iters | median wall 32.45 ms (~30.8 k docs/s) |

Window/warmup: 50-op warmup then 10 s sustained window for blob puts;
downloads and reads timed per-op sequentially; query wall from 5 iterations.

## TS-vs-Python comparison table (B-2/B-3)

PENDING — `docs/jira/v26.10.14/bench/` contains b4/b6/b7/b9 but no
`b2-*.jsonl` / `b3-*.jsonl` at receipt time (2026-10-15, this lane's run).
Once B-2/B-3 land, compare on the mirrored ops:

| op | Python (this lane) | TS (B-2/B-3) | delta |
|---|---|---|---|
| blob put-block-blob 8 KiB ops/s | 917.2 | pending | pending |
| blob download MB/s | 744.2 MiB/s (1 MiB blob) | pending | pending |
| cosmos point read p50 | 3.225 ms | pending | pending |
| cosmos 1000-doc scan wall | 32.45 ms | pending | pending |

The JSONL records carry the full per-measure detail for whoever lands B-2/B-3
to compute the deltas.

## Substrate divergences found (real, blocking the mirrored surface)

1. **Put Block List stores the request body as blob content.** Staging
   `N` blocks then `commit_block_list` leaves a blob whose body is the
   `<?xml ...><BlockList>...` request XML (e.g. 390 bytes for a 7.5 MiB
   staged payload) instead of the concatenated blocks. SDK download
   "succeeds" with the wrong bytes — silent data corruption on the block
   path. Verified with azure-storage-blob 12.31.0 on the b5 private
   substrate. Blocks: `stage_block` (Put Block) works; only the commit
   concatenation is wrong.
2. **Get Block List returns wrong content-type.** `?comp=blocklist&blocklisttype=all`
   responds `Content-Type: application/octet-stream` instead of
   `application/xml`, so azure-storage-blob raises `DecodeError: Cannot
   deserialize content-type: application/octet-stream` (HTTP 200 from the
   substrate). Put Block itself returns correct XML content type.

Also noted: per-PUT body cap is 1,048,576 bytes (larger single puts refused
with `RequestBodyTooLarge`); the download measure therefore uses a 1 MiB blob
by single Put Blob.

## Receipt

- commands: `bash -c 'source scripts/bench/lib.sh && pid=$(bench_boot b5) …'`
  (pid 72356); two venv invocations of `scripts/bench/b5_python_mirror.py`
  (`blob`, then `cosmos`); final clean run wrote the 4 JSONL records.
- verification: JSONL on disk at
  `docs/jira/v26.10.14/bench/b5-python-mirror.jsonl` — re-read at write time,
  all errors=0, cosmos full scan returned exactly 1000 docs per iteration.
- teardown: substrate killed (bench_down on pid 72356) after final run.
- no commits, no lib.sh/SDK edits (lib.sh log-dir bug worked around by
  pre-creating `docs/tmp/` — cd-before-mkdir ordering in `bench_boot`).

---

## RE-MEASURE addendum (2026-10-22, lane BK-BQUIET — quiesced-machine attempt)

- **Standing**: PARTIAL_ALIVE (re-witnessed under residual load; see typing below)
- **Context**: solo
- Attempt context: `just quiesce` REFUSED (foreign substrate on court ports,
  foreign beam outside checkout, load > threshold); bounded 15-min poll never
  cleared (load 78 -> 103 in this lane's window). Pass proceeded under
  residual load, typed honestly. Environment note: the receipt's venvs
  (.venv-blob/.venv-cosmos under test/sdk-python) no longer exist; the SDK
  (azure-storage-blob 12.31.0, system Python 3.14) is importable system-wide
  and the driver ran under it directly — same real SDK, not a substitute.
- Replay (real, exit-captured): private block 39050..39055 substrate, then
  `python3 scripts/bench/b5_python_mirror.py {blob,cosmos}` against egress
  127.0.0.1:39051. Original 4 jsonl rows snapshotted and restored byte-exact
  (sha256 c6a97aca...) — re-measure rows live in tmp/bkbquiet only.

```
PRE-B5 load={ 97.39 85.99 97.61 } 2026-10-22T14:11:46Z
BLOB DONE: put 3279 ops, download 234.4 MiB/s
{"lane": "b5", "surface": "blob", "op": "put_block_blob_8k", "n": 3279, "ops_per_sec": 327.9, "p50_ms": 2.255, "p95_ms": 3.726, "p99_ms": 20.651, "errors": 0, ...}
{"lane": "b5", "surface": "blob", "op": "download_1mib", "n": 20, "ops_per_sec": 234.39, "p50_ms": 3.36, "p95_ms": 12.145, "p99_ms": 12.318, "errors": 0, ...}
{"lane": "b5", "surface": "cosmos", "op": "point_read", "n": 500, "ops_per_sec": 103.16, "p50_ms": 7.135, "p95_ms": 20.993, "p99_ms": 57.841, "errors": 0, ...}
{"lane": "b5", "surface": "cosmos", "op": "query_select_all_1000docs", "n": 1000, "ops_per_sec": 15797.67, "p50_ms": 63.3, "errors": 0, ...}
POST-B5 load={ 103.51 88.13 98.03 } 2026-10-22T14:12:10Z
```

- Verdict: **PASS (load-typed)**. 4/4 measures, 0 errors; rates ~3-8x below
  the 2026-10-15 baseline (328 vs 917 ops/s blob puts), consistent with
  residual load. Full rows: tmp/bkbquiet/b5-python-mirror-remeasure.jsonl.
