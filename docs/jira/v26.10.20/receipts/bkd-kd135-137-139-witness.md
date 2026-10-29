# Witness: B-KD wire evidence for KD-135 / KD-137 / KD-139 (post-shim)

- **Date**: 2026-10-21 (lane B-KD)
- **Standing**: ALIVE
- **Context**: pair
- **Shims under witness**: `lib/smalt/egress_router.ex` (KD-137 range arm,
  KD-139 ensure_put_blob_type, KD-135 container put arm),
  `lib/smalt/data_plane/blob_storage.ex` (KD-135 default flip); shim mtimes
  2026-10-21 10:23/10:24 local, BEFORE this receipt (mtime gate satisfied).
- **Method**: live wire probe via curl against the running substrate data
  plane (127.0.0.1:8443), bearer from the emulator STS
  (`POST /dev/oauth2/v2.0/token`, exit 0, token 1263 chars), all requests
  carrying `x-ms-version: 2021-08-06`. Real output below, captured 2026-10-21.

## KD-139 — headerless Put Blob → 400 MissingRequiredHeader (XML face)

```
PUT /devstoreaccount1/kdprobe/nohint.txt   (no x-ms-blob-type)
HTTP/1.1 400 Bad Request
x-ms-error-code: MissingRequiredHeader
content-type: application/xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?><Error><Code>MissingRequiredHeader</Code><Message>An x-ms-blob-type header is required for Put Blob.</Message></Error>
```
PASS — azurite/real-Azure matching status + code + XML StorageError face.

## KD-137 — x-ms-range past EOF → 416 InvalidRange (XML face)

```
PUT .../kdprobe/short.txt (x-ms-blob-type: BlockBlob, 10 bytes) → 201
GET .../kdprobe/short.txt  x-ms-range: bytes=1000-2000
HTTP/1.1 416 Requested Range Not Satisfiable
x-ms-error-code: InvalidRange
content-type: application/xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?><Error><Code>InvalidRange</Code><Message>The range specified is invalid for a blob of 10 bytes.</Message></Error>
```
PASS — 416 InvalidRange with the code in `x-ms-error-code` header and
StorageError XML body (matches the real-Azure authority named in the row).

## KD-135 — delete on default (non-WORM-opt-in) container → 202

```
PUT /devstoreaccount1/kdprobe2?restype=container   → 201
PUT .../kdprobe2/del.txt (BlockBlob)               → 201
DELETE .../kdprobe2/del.txt
HTTP/1.1 202 Accepted
```
PASS — delete succeeds on a default container; immutability is opt-in via
`x-ms-immutable-policy`, matching azurite/real Azure.

Cleanup: blob 202, container 202. Probe count: 3 faces / 3 PASS / 0 FAIL.
