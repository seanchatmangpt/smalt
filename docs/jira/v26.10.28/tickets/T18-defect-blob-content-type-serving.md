# T-18 — DEFECT: content-type from Set Blob HTTP Headers not served back

- window: v26.10.28 · origin: parity lane defect (commit `8a6ce57` known-issues) · verdict-at-open: **DEFECT**
- size: **S** · depends-on: — · parity-leg: blob suite rows `blob-set-http-headers`, `blob-content-type-after-headers`, `blob-get-properties`

## current state (evidence)

`set_blob_http_headers/4` (added in commit `8a6ce57`,
`lib/smalt/data_plane/blob_storage.ex`) stores the `x-ms-blob-content-*`
request headers into the blob record and answers 200 — but the HEAD/GET
arms serve a hardcoded `application/octet-stream`
(`lib/smalt/egress_router.ex` HEAD blob arm, `put_resp_content_type`
call sites), so the stored value never reaches the client. Receipt:
`parity/reports/mvsqkf7q-36121c/report.md` — smalt serves
`application/octet-stream; charset=utf-8` after setting `text/plain`
(Azurite serves `text/plain`).

## scope

1. HEAD blob and GET download arms read the stored
   `x-ms-blob-content-type` (and cache-control/disposition where the SDK
   surfaces them) from the blob record, falling back to octet-stream when
   unset.
2. Azure semantics preserved: Set HTTP Headers with the header ABSENT
   REMOVES the stored value (the storage side already does this —
   Map.drop + take; the serving side is the fix).

## Definition of Done — the Azure developer's view

You upload a block blob, then call
`blobClient.setHTTPHeaders({ blobContentType: "application/json" })` —
exactly as your production code does after uploading an API response.
From that moment, `blobClient.getProperties()` reports
`contentType: "application/json"`, and downloading the blob (or an HTTP
HEAD from curl) returns that content type, so the browser/HTTP client on
the other end renders or parses it correctly instead of forcing a
download. Clearing it by setting an empty headers object reverts to the
default. The parity suite's content-type rows MATCH Azurite.

## receipts required

Set→HEAD→download content-type receipt (all three consistent); removal
receipt (absent header clears); parity rows MATCH.
