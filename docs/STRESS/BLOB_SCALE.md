# BLOB_SCALE — Smalt Immutable Blob Storage Scale Receipt

Harness: `scripts/stress/blob_scale.py` (stdlib-only Python, fail-closed).
Substrate: `mix run --no-halt` spawned by the harness (MIX_ENV=dev), data plane
on 127.0.0.1:8443, auth enforced — the harness mints a real HS256 Bearer from
the ARM STS (`POST :9443/oauth2/v2.0/token`) and sends it on every request.
Receipt: `tmp/blob-scale-receipt.json` (schema `smalt-blob-scale/v1`).

Latest run: 2026-10-14, exit 0, 6 scenario records, 6 boundaries.

## Results

| # | Scenario | Result |
|---|---|---|
| 1 | 8 MiB single-blob PUT/GET | **BOUNDARY**: PUT resets the connection. Pinned: largest accepted body is exactly 8,000,000 bytes (`1MB`→201, `4MB`→201, `8,000,000`→201, `8,000,001`→connection reset, `16MB`→broken pipe). 8 MiB (8,388,608 B) exceeds the bound. |
| 2 | 500 KB x 100 PUT/GET | PUT 100/100 ok, 162.89 MB/s (p50 2.818ms, p95 3.961ms); GET 100/100 ok, 917.5 MB/s (p50 0.515ms, p95 0.649ms), all GETs byte-identical |
| 3 | Ranged GET (10 x 50KB of 500KB) | 10/10 correct 206 + exact `Content-Range` + byte-exact slices; p50 0.383ms, p95 0.466ms |
| 4 | 5,000-blob container listing | seed 5000 in 0.6s, 0 errors; full XML list 19.4ms / 1.14 MiB; well-formed (ElementTree-parsed); **defect**: returns 5,105 entries, not 5,000 (see D2) |
| 5 | WORM 409 under concurrency | 50 threads overwrite one immutable blob: **50/50 → 409 ContainerLocked, zero accidental 201**, original payload intact, 0.015s wall (~3,300 req/s refusal path) |

## Boundaries (documented, not fixed)

- **B1 — PUT body hard bound: 8,000,000 bytes.** The blob PUT route
  (`lib/smalt/egress_router.ex` PUT /:account/:container/:blob) matches
  `{:ok, raw_body, conn} = Plug.Conn.read_body(conn)`; the default
  `:length` is 8_000_000, larger bodies return `{:more, data, conn}`, the
  head does not match → handler crash → connection reset (8,000,001) /
  broken pipe (16MB). Clients see a TCP-level failure, not an HTTP error.
- **B2 — Binary (invalid UTF-8) content PUT → 500 with empty body, blob
  still persists.** The route echoes the stored blob map (which embeds the
  raw `"content"`) through `Jason.encode!`; raw binary raises and the client
  sees 500 even though `store_blob` already committed. Probe: 512-byte
  invalid-UTF-8 body → PUT 500, GET returns the bytes byte-identical.
- **B3 — Blob listing has no marker pagination.** `GET
  /{acct}/{container}?marker=...&maxresults=50` returns the identical
  unpaginated XML; marker/maxresults exist only for container listing
  (`BlobService.list_containers`, max page 50). Blob listing always serves
  all blobs in one response (`BlobStorage.list_blobs_xml/2`).
- **D2 (defect) — Cross-container listing leak.** `BlobStorage.list_blobs_xml/2`
  filters with `String.starts_with?("#{account}/#{container}/#{b["name"]}",
  prefix)` — the key is rebuilt with the LISTED container, so any blob in the
  account with a same-shaped name is included. Measured: container holds 5,000,
  listing returned 5,105 (5,102 / 5,105 across runs — whatever same-named
  blobs exist account-wide). XML stays well-formed; the count is wrong.
- **B4 — WORM containers are undeletable by design** (immutable default,
  retention 1095d → container DELETE is 409-refused). Run isolation relies on
  the in-memory ETS store dying with the substrate.

## Reproduce

```
python3 scripts/stress/blob_scale.py        # receipt -> tmp/blob-scale-receipt.json
```

No git commands run; only owned files touched
(`scripts/stress/blob_scale.py`, `docs/STRESS/BLOB_SCALE.md`).
