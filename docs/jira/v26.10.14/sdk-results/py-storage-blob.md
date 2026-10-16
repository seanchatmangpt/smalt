# PY-2 — Python azure-storage-blob SDK against the egress blob plane (8443)

Subject: `/Users/sac/smalt` v26.10.14, lane PY-2, 2026-10-15.
Harness: `test/sdk-python/py_storage_blob.py`, venv `test/sdk-python/.venv-blob`
(azure-storage-blob **12.31.0**, Python 3.14.3). Auth: SharedKey via connection
string (account `smaltacct`), mirroring `test/sdk-smoke/blob.test.cjs`. Mutable
containers opt out of WORM via raw `PUT` with `x-ms-immutable-policy: false`
(substrate extension not exposed by the Python SDK).

Substrate: shared live substrate already holding the exclusive
`/tmp/smalt-substrate.lock` (anonymous mode, anonymous-mode 9443/8443/5672 all
accepting). Attached to it rather than booting a second one; **not killed on
exit** — other lanes hold the lock.

## Results — 7 PASS / 3 documented divergences (exit 0 with divergences as FAIL rows)

| # | Probe | Result | Detail |
|---|---|---|---|
| 01 | Create container (default immutable) | PASS | 201 |
| 02 | Create container, WORM opt-out header | PASS | 201 |
| 03 | Block blob upload/download roundtrip (multibyte UTF-8) | PASS | etag `dae6fdda…`, 39 bytes byte-identical |
| 04 | Set Blob Metadata → Get Properties | **DIVERGENCE** | `PUT ?comp=metadata` returns **201 Created**; Azure/spec returns **200 OK**. SDK 12.31.0 raises `HttpResponseError: Operation returned an invalid status 'Created'`. Raw curl confirmed: `HTTP/1.1 201 Created` on `?comp=metadata`. |
| 05 | List Blobs (delimiter, include=metadata, results_per_page) | **DIVERGENCE** | `GET ?restype=container&comp=list` XML undeserializable by the SDK: `BlobProperties` missing required elements (`BlobType`, `LeaseStatus`, `Content-Type`, …) and `<Last-Modified>` emitted **ISO-8601**, not RFC-1123. Raw XML captured (only Content-Length/Etag/Last-Modified present). Also `<Prefix>` echoes `smaltacct/<container>/` (Azure does not echo an account-prefixed Prefix on container list). |
| 06 | List with junk `maxresults=-7` | PASS | **400** "Value for maxresults is invalid (must be a positive integer)" |
| 07 | Conditional read, stale If-Match | PASS | **412** on stale etag |
| 08 | Delete blob | PASS | 202, subsequent `exists()` false |
| 09 | Overwrite on immutable container | PASS | **409 ContainerLocked** |
| 10 | Get Container Properties (RFC-1123 Last-Modified) | **DIVERGENCE** | `GET/HEAD ?restype=container` returns `last-modified: 2026-10-15T23:07:40.375Z` (ISO-8601). Spec/Azure: RFC-1123. SDK raises `DeserializationError … rfc-1123`. Note: **Create Container** response correctly returns RFC-1123 — the divergence is Get Properties only. |

## Falsifiers

- D-04: re-run `py_storage_blob.py` probe 04 after `?comp=metadata` returns 200 → FAIL row converts to PASS.
- D-05: re-run probe 05 after List Blobs XML carries full BlobProperties + RFC-1123 dates → PASS.
- D-10: re-run probe 10 after Get Container Properties emits RFC-1123 Last-Modified → PASS.

## Files added

- `test/sdk-python/py_storage_blob.py`
- `test/sdk-python/.venv-blob/` (venv, not committed material)

No `lib/` or existing `test/` files touched.
