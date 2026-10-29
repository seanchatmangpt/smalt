# KD-02 witness — blob comp=list BlobProperties + Prefix echo

- **Standing:** PASS
- **Context:** solo
- **Date:** 2026-10-21
- **Lane:** K1 (divergence-finish, blob face)
- **Subject:** `lib/smalt/data_plane/blob_storage.ex` `render_blob/4`, `blob_content_type/1`, prefix echo (`# KD-COVERS: KD-02`)

## Divergence (registered)

BlobProperties missing required elements (BlobType, LeaseStatus,
Content-Type, ...) and `<Last-Modified>` ISO-8601 not RFC-1123;
`<Prefix>` echoes the account-prefixed path. Falsifier: full
BlobProperties + RFC-1123 dates.

## State at triage (pre-existing landings + this lane)

Already landed before this lane: `BlobType` and RFC-1123 `Last-Modified`
(KD-107 rider). This lane completes the set: `Content-Type` (from the
stored Put-Blob headers, `application/octet-stream` fallback),
`LeaseStatus`/`LeaseState`, and the Prefix echo now emits the REQUESTED
prefix verbatim (`<Prefix></Prefix>` when absent) instead of the stored
account-prefixed key path — both render sites (fast path + delimiter
composition path).

## Live-wire evidence (substrate :8443, STS bearer)

```
$ curl -s -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2023-11-03' \
    'http://127.0.0.1:8443/devstoreaccount1/k1c2?restype=container&comp=list'
<?xml version="1.0" encoding="utf-8"?>
<EnumerationResults ServiceEndpoint="http://127.0.0.1:8443/devstoreaccount1" ContainerName="k1c2">
  <Prefix></Prefix>
  <Marker></Marker>
  <MaxResults>50</MaxResults>
  <Blobs>
<Blob>
  <Name>k1blob.txt</Name><Properties>
    <Content-Length>8</Content-Length>
    <Etag>&quot;74e3c8827672dce1eaca08911f04d336&quot;</Etag>
    <BlobType>BlockBlob</BlobType>
    <Content-Type>application/x-www-form-urlencoded</Content-Type>
    <LeaseStatus>unlocked</LeaseStatus>
    <LeaseState>available</LeaseState>
    <Last-Modified>Wed, 21 Oct 2026 02:19:43 GMT</Last-Modified>
  </Properties>
</Blob>
```

(RFC-1123 date witnessed; Content-Type echoes the curl default
content-type the PUT stored — wire-observed, not curated.)

## Plug-conn court

`test/integration/blob_k1_rows_witness_test.exs` — asserts Content-Type /
LeaseStatus / LeaseState / BlobType / RFC-1123 Last-Modified regex +
`<Prefix></Prefix>` / `<Prefix>dir/</Prefix>` echo. 6 tests, 0 failures.
