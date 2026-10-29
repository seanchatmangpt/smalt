# BK-18: KD-142 blob error envelope — live wire witness + flip

**Standing:** ALIVE — KD-142 close condition satisfied on live substrate HEAD (pid 53160, shared lane boot); flip applied receipt-gated.
**Context**: solo

## Subject

KD-142 (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`, the only OPEN blob-class
error-contract row): smalt rendered blob-face errors as JSON
`{"error":{...}}` with no `x-ms-error-code` response header. KD-135/136/138
were already CLOSED-WITH-RECEIPT (bk13 re-verified); KD-137/139/140/141
CLOSED-SIMULATED. The systemic envelope row KD-142 remained OPEN.

## BEFORE (recorded divergence)

`popcorn_demo/azurite-spike/error-census.jsonl` (census W30-D run 2,
2026-10-21): blob-face error rows show JSON body, smalt code field null, no
`x-ms-error-code` header (e.g. InvalidRange row: smalt code=null, azurite
code=InvalidRange). The fix shim had already landed
(`lib/smalt/data_plane/blob_error.ex`, `# KD-COVERS`-adjacent renderer +
`lib/smalt/egress_router.ex:3735` face gate on `:smalt_blob_face`), so a live
BEFORE re-capture would require mutating a shared boot; the census file is
the cited BEFORE evidence per the row's own evidence column.

## AFTER — live wire evidence (substrate UP, HEAD)

STS token (enforce mode), real HTTP over port 8443, exact bodies:

```
=== shape A: GET x-ms-range past EOF on 10-byte blob ===
HTTP/1.1 416 Requested Range Not Satisfiable
x-ms-request-id: 7b5154b9-0cf1-4387-8dff-233267c7a412
x-ms-version: 2021-12-02
x-ms-error-code: InvalidRange
content-type: application/xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?><Error><Code>InvalidRange</Code><Message>The range specified is invalid for a blob of 10 bytes.</Message></Error>
```

```
=== shape B: PUT blob without x-ms-blob-type (KD-139 face) ===
HTTP/1.1 400 Bad Request
x-ms-error-code: MissingRequiredHeader
content-type: application/xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?><Error><Code>MissingRequiredHeader</Code><Message>An x-ms-blob-type header is required for Put Blob.</Message></Error>
```

```
=== shape C: GET blob missing x-ms-version (KD-136 face) ===
HTTP/1.1 400 Bad Request
x-ms-error-code: MissingXMsVersion
content-type: application/xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?><Error><Code>MissingXMsVersion</Code><Message>Missing required x-ms-version header, SAS token, or allowlisted host.</Message></Error>
```

```
=== control: GET missing blob ===
HTTP/1.1 404 Not Found
x-ms-error-code: BlobNotFound
content-type: application/xml; charset=utf-8
<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobNotFound</Code><Message>BlobNotFound</Message></Error>
```

## Negative leg (non-vacuity, face scoping)

```
=== KV face 404: JSON body, BlobError NOT applied ===
HTTP/1.1 404 Not Found
content-type: application/json; charset=utf-8
{"error":{"code":"SecretNotFound"}}
```
```
=== ARM face 400 (port 9443): JSON body ===
HTTP/1.1 400 MissingApiVersionParameter
content-type: application/json; charset=utf-8
{"error":{"code":"MissingApiVersionParameter",...}}
```
Blob XML envelope is blob-face-scoped; other faces byte-identical to their
prior contracts. Note: KV 404s carry their own `x-ms-error-code` header with
a JSON body (pre-existing KV-face convention, not the BlobError renderer).

## Environment receipt

| step | command | exit |
|---|---|---|
| toolchain | asdf elixir 1.20.4-otp-29 / erlang 29.1.2 (homebrew 1.19.5 refuses mix.exs `~> 1.20`) | 0 |
| warm compile | `MIX_BUILD_ROOT=_build-bk18 mix compile` | 0 |
| substrate | `scripts/substrate.sh status` → UP pid 53160 (shared lane boot on HEAD; shim files committed, no local lib edits needed) | 0 |
| STS token | `curl -X POST http://127.0.0.1:9443/organizations/oauth2/v2.0/token -d 'grant_type=client_credentials&client_id=dev&client_secret=dev&resource=http://127.0.0.1:8443'` | 200 |
| probes | curl legs above (bounded, no sleeps) | — |

## Flip

```
python3 scripts/kd_flip.py --apply   # KD-142: OPEN -> CLOSED-WITH-RECEIPT
```
Gate: this receipt postdates the shim mtimes (blob_error.ex 1792602xxx,
egress_router KD-COVERS tokens 1792602516-659). No hand edit of the register
row body.

## Falsifier status

None outstanding: the row's own falsifier ("smalt renders StorageError XML
with x-ms-error-code on the census shapes... witness postdating any shim")
is discharged by shapes A-C above. KD-137/139/140/141 per-face rows remain
status-gated independently; KD-142's single-flip clause applies.

## Addendum: KD-COVERS token landed (post-witness)

The envelope renderer gate (`lib/smalt/egress_router.ex` `blob_error/3`,
`:smalt_blob_face` typed-error branch) carried no `# KD-COVERS: KD-142`
token — the disposition note in the row cited tokens for KD-137/139/140 only,
so kd_flip's covers-map never saw KD-142. Token landed as a comment-only edit
(no behavior change; `MIX_BUILD_ROOT=_build-bk18 mix compile` exit 0),
receipt re-stamped post-token so the mtime gate passes lawfully.
