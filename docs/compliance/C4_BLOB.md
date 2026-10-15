# C4_BLOB

Azure Blob Service REST conformance of smalt's blob surface, validated against
the real Blob Service REST contract by live probes (curl over real sockets
against a booted `Smalt.EgressRouter`) plus the wire fence tests in
`test/compliance/c4_blob.exs` (14 tests, 0 failures, 2026-10-15).

Subject: `~/smalt` @ working tree 2026-10-15. Probe receipts inline.

## Scope

- `lib/smalt/data_plane/blob_storage.ex` (container/blob engine)
- `lib/smalt/data_plane/blob_service.ex` (service/container level)
- `lib/smalt/egress_router.ex` (wire layer, port 8443)
- `lib/smalt/auth/bearer.ex` (auth plug)

## Verdict summary

| Area | Verdict |
|---|---|
| SharedKey authorization | DEV-MODE (never validated) |
| x-ms-version required | PARTIAL (400 enforced, wrong code string, wrong body format) |
| x-ms-date | GAP (not required/validated) |
| Container PUT | GAP (no ETag/Last-Modified headers; non-empty JSON body) |
| Container GET properties | CONFORMANT |
| comp=metadata PUT/GET | CONFORMANT |
| comp=lease | GAP (absent; request mis-routed to create) |
| comp=list blobs XML | CONFORMANT (schema) / minor deviations |
| comp=list containers XML | CONFORMANT (schema) |
| Blob PUT | PARTIAL (octet-stream CONFORMANT; urlencoded/json DEV-MODE) |
| Blob GET (200/206/416) | CONFORMANT |
| Blob GET conditional (304) | GAP |
| Blob DELETE | PARTIAL (202 shape; no x-ms-delete-type-permanent) |
| comp=immutabilityPolicy PUT | BUILD-BROKEN on wire (500) |
| comp=immutabilityPolicy GET | GAP (JSON, real = XML) |
| comp=legalhold PUT/GET | PARTIAL |
| Error envelope / code strings | PARTIAL |
| 409 vs 412 selection | CONFORMANT |
| WORM semantics | DEV-MODE (default-immutable containers) |

## Rows

### SharedKey authorization — DEV-MODE

Real service: `Authorization: SharedKey account:signature` HMAC-SHA256 over
canonicalized headers + canonicalized resource; a bad signature is rejected
403 `AuthenticationFailed`.

smalt has NO SharedKey path at all. The only auth is the Bearer plug
(`lib/smalt/auth/bearer.ex:40-48`): in `:enforce` mode a `SharedKey` header is
refused 401 `MalformedBearerHeader` (bearer.ex:88-94); in `:anonymous` mode
(test default, config/test.exs:7) ANY request passes, including a bogus
SharedKey. Live probe: `PUT ?restype=container` with
`Authorization: SharedKey c4acct:totally-bogus-signature==` → **201 Created**
(anonymous mode). smalt never computes or compares any storage account key
signature.

### x-ms-version — PARTIAL

Real service: missing `x-ms-version` (versions after 2009-09-19) → 400
`MissingRequiredHeader`. smalt enforces presence via the blob_route guard
(`lib/smalt/egress_router.ex:1005-1026`): probe `GET /{a}/{c}` without the
header → **400** with JSON body `{"error":{"code":"MissingXMsVersion"}}`
(egress_router.ex:1019-1021). Code string `MissingXMsVersion` is NOT a real
Blob service error code (real: `MissingRequiredHeader`); body is JSON where
the real service returns XML `<Error><Code>...`.

### x-ms-date — GAP

Real service requires `x-ms-date` (or Date) for 2011-08-18+ versions and
rejects stale dates. smalt never reads `x-ms-date` anywhere on blob routes.

### Container PUT — GAP

Real: `PUT ?restype=container` → 201 with `ETag` and `Last-Modified` response
headers and empty body. smalt (`egress_router.ex:683-689`) returns 201 with a
JSON body (the account/container record) and NO ETag/Last-Modified headers.
Live probe headers: `content-type: application/json`, no etag.

### Container GET properties — CONFORMANT

Real shape matched: 200 + `ETag`, `Last-Modified`, `x-ms-meta-*`,
`x-ms-has-immutability-policy`, `x-ms-has-legal-hold`, `x-ms-request-id`,
`x-ms-version` (`lib/smalt/data_plane/blob_service.ex:164-186`). Live probe
confirmed all seven header families present. HEAD container mirrors it
(egress_router.ex:899-922). Deviation: real `Last-Modified` is RFC 1123
(`Thu, 15 Oct 2026 04:50:47 GMT`); smalt emits ISO8601
(`2026-10-15T04:50:47.213Z`) — noted, not fenced.

Last-Modified format deviation (ISO8601 vs real RFC 1123) noted above;
otherwise shape-conformant.

### comp=metadata — CONFORMANT

PUT 200 + ETag; GET 200 + `x-ms-meta-*` headers
(`blob_service.ex:116-151`, egress_router.ex:670-681, 729-743). Round-trip
fenced in c4_blob.exs.

### comp=lease — GAP

No lease route exists. `PUT ?comp=lease` falls through to the create-container
branch (egress_router.ex:683-689): live probe of lease-acquire → **201** with
the container record body — the request is silently mis-interpreted as
container creation instead of refused. Real: 201 + `x-ms-lease-id` (or 409).

### comp=list blobs — CONFORMANT schema, minor deviations

XML skeleton `EnumerationResults[@ContainerName]/Blobs/Blob/Properties/{Name,
Content-Length, Etag, Last-Modified}` + `NextMarker` present/absent semantics
(`lib/smalt/data_plane/blob_storage.ex:302-346`), lexicographic order,
marker paging fenced over the wire in c4_blob.exs. Deviations: `Content-Type`
property never emitted (real always emits it); `<Prefix>` echoes the stored
account key prefix (`acct/cont/`) instead of the `prefix` query param.

### comp=list containers — CONFORMANT schema

`GET /{account}?comp=list` → EnumerationResults/Containers/Container with
Name/Properties{Last-Modified, Etag, LeaseStatus, PublicAccess,
HasImmutabilityPolicy, HasLegalHold}
(`lib/smalt/data_plane/blob_service.ex:68-106`). Fenced in c4_blob.exs.

### Blob PUT — PARTIAL

octet-stream path CONFORMANT: 201 + `ETag` header, content stored byte-exact
(GET round-trip fenced). Real Put Blob also returns x-ms-request-id/
x-ms-version — smalt emits neither on blob PUT.

DEV-MODE defect (probe-witnessed): for `application/x-www-form-urlencoded` or
`application/json` request content-types, `Plug.Parsers` (egress_router.ex:54-58)
consumes the body before the route's `read_body` — the blob is stored EMPTY
(live probe: PUT "hello world" urlencoded → ETag `d41d8cd9...` = MD5 of empty
string; content-length 0 in list). Only octet-stream (what the Azure SDKs
send) is safe. Related: `{:error, term, conn}` clause at egress_router.ex:821
is unreachable for the body path (dead clause, compiler-warning corroborated).

Dead clause noted (egress_router.ex:821, compiler corroborated).

### Blob GET — CONFORMANT (200/206/416)

200 full body with ETag + Content-Length; 206 + `Content-Range: bytes f-l/n`
via `x-ms-range` or `Range` (egress_router.ex:829-874, engine
blob_storage.ex:232-255, 257-287); 416 with `Content-Range: bytes */n` and
code `InvalidRange` (real code string matches). Fenced in c4_blob.exs.

### Blob GET conditional — GAP

Real: `If-None-Match` match → 304. smalt's blob GET never evaluates
If-None-Match (route at egress_router.ex:829-874 has no conditional call;
`ConditionalHeaders.evaluate/2` supports `{:halt, 304}` —
`lib/smalt/data_plane/conditional_headers.ex:13-25` — but Cosmos is the only
caller). Live probe: GET with matching If-None-Match → **200** (real: 304).

### Blob DELETE — PARTIAL

202 + `x-ms-request-id` + `x-ms-version` on success
(`blob_storage.ex:111-112`); 404 `BlobNotFound` exact code string; 409
`ContainerLocked` on WORM block. Real Delete Blob also emits
`x-ms-delete-type-permanent` — smalt does not.

### comp=immutabilityPolicy PUT — BUILD-BROKEN (wire)

The wire path 500s. Two stacked defects, probe-witnessed twice:

1. `Plug.Parsers` consumes the JSON policy body before
   `read_body` in the route (egress_router.ex:655), so `policy_from_wire/1`
   (egress_router.ex:1409-1425) parses `""` → empty policy — the caller's
   requested period/lock is never applied.
2. With an empty policy, `until` is nil and `set_immutability_policy/5`
   returns `"immutability-policy-until" => nil` (blob_storage.ex:155); the
   router's `put_resp_header(conn, "immutability-policy-until", nil)`
   (egress_router.ex:660-663) raises FunctionClauseError → 500.

Probe: `PUT ?comp=immutabilityPolicy` (JSON body) → **500** (connection closed,
empty response) for both set and lock attempts. The engine-level
`BlobStorage.set_immutability_policy/5` (blob_storage.ex:127-165) is fine; the
wire parse + nil-header serialization is broken.

### comp=immutabilityPolicy GET — GAP

Real: 200 with XML `<ImmutabilityPolicy><ImmutabilityPeriodSinceCreationInDays>
30</...><ImmutabilityPolicyUntil>...</...></ImmutabilityPolicy>`. smalt returns
JSON `{"locked":false,"period_days":0,"until":null}` (egress_router.ex:697-711).
Snake_case JSON where the real service returns XML with PascalCase elements.

### comp=legalhold — PARTIAL

PUT 200 with `x-ms-has-legal-hold` header matches the real contract; smalt
additionally returns a JSON body `{"has_legal_hold":true}` (snake_case) where
the real service returns an EMPTY body (egress_router.ex:633-649). GET returns
`x-ms-legal-hold` header + empty body — conforms. Fenced in c4_blob.exs.

### Error envelope / code strings — PARTIAL

Codes CONFORMANT: `BlobNotFound`, `ContainerNotFound`, `ContainerLocked`,
`PreconditionFailed`, `InvalidRange`. Mismatches: `MissingXMsVersion` (real:
`MissingRequiredHeader`); `ImmutabilityPolicyNotFound`/`LegalHoldNotFound`
(egress codes at egress_router.ex:709, 725) are not real Blob service error
code strings. Envelope is JSON `{"error":{"code","message"}}` where the real
Blob service returns XML `<Error><Code>...</Code><Message>...</Message></Error>`.
Also: `comp=list` against a nonexistent container returns **200 empty list**
(egress_router.ex:745-758, probe-witnessed) where real returns 404
`ContainerNotFound`.

comp=list on missing container → 200-empty (real: 404 ContainerNotFound).

### 409 vs 412 selection — CONFORMANT

409 `ContainerLocked` for WORM/lease-class conflicts; 412
`PreconditionFailed` for If-Match failures — matches the real service's
selection. Fenced (412 on stale If-Match, 409 on WORM delete).

### WORM semantics — DEV-MODE

Real containers are NOT immutable by default; immutability requires an
explicit immutability policy. smalt defaults `immutable: true` +
`retention_days: 1095` (`blob_storage.ex:19-20`) — every container is
WORM-locked for 3 years out of the box (probe: delete on a default container →
409 ContainerLocked "container policy enforces immutable WORM retention").
The real service has no container-level time source of truth like
`created_at + retention_days`; the real WORM clock is per-policy
`ImmutabilityPolicyUntil`. smalt mixes container-creation-clock retention with
policy lock state (blob_storage.ex:410-428).

## Fence tests

`test/compliance/c4_blob.exs` — 14 wire tests over real Bandit/:httpc
sockets, fencing only CONFORMANT rows:

x-ms-version 400 guard, container properties header contract, metadata
round-trip, 404 ContainerNotFound, container+blob list XML schemas, blob PUT/
GET byte-exact round-trip + ETag, 206/416 range semantics, 404 BlobNotFound,
DELETE 202 shape, If-Match 412 + matched 201, WORM 409 ContainerLocked,
legal hold header contract, pagination NextMarker.

Result: `mix test test/compliance/c4_blob.exs` → **14 tests, 0 failures**
(2026-10-15).
