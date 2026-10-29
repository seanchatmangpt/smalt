# KD-66 witness — blob ranged-GET Content-MD5

- **Standing:** PASS
- **Context:** live substrate wire, solo lane
- **Date:** 2026-10-21
- **Lane:** K1 (divergence-finish, blob face)
- **Subject:** `lib/smalt/egress_router.ex` 206 arm of the blob GET route (`# KD-COVERS: KD-66`)

## Divergence (registered)

`x-ms-range-get-content-md5`/`crc64` ignored — full-200 with no
Content-MD5 header. Falsifier: ranged GET with the header → Content-MD5
present or typed refusal.

## Fix

In the single-range 206 arm: when `x-ms-range-get-content-md5` is
`true`/`True`, compute the base64 MD5 of the returned range bytes and set
`content-md5`. Without the request header the wire is unchanged
(verified). crc64 remains absent (Azure parity: only md5 today; the row
offered "Content-MD5 present OR typed refusal" — Content-MD5 present).

## Live-wire evidence (substrate :8443, STS bearer)

```
$ # PUT container k1c2 201, PUT k1blob.txt "hello k1" 201
$ curl -s -D - -o /dev/null -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2023-11-03' \
    -H 'x-ms-range: bytes=0-4' -H 'x-ms-range-get-content-md5: true' \
    'http://127.0.0.1:8443/devstoreaccount1/k1c2/k1blob.txt' | grep -i 'HTTP/\|content-md5'
HTTP/1.1 206 Partial Content
content-md5: XUFAKrxLKna5cZ2REBfFkg==
$ python3 -c "import base64,hashlib;print(base64.b64encode(hashlib.md5(b'hello').digest()).decode())"
XUFAKrxLKna5cZ2REBfFkg==      # exact match
```

Without the request header: 206 with NO `content-md5` (unchanged wire,
plug-conn asserted).

## Plug-conn court

`test/integration/blob_k1_rows_witness_test.exs` — 6 tests, 0 failures
(embedded in the KD-67 receipt; same court file).

## Flip-gate refresh

Final compile + wire witness postdate the KD-COVERS edit; this refresh
keeps the receipt newer than the shim for the kd_flip mtime gate.
