# C4_BLOB

Azure Blob Service REST conformance of smalt's blob surface, validated against
the real Blob Service REST contract by live probes (curl over real sockets
against a booted `Smalt.EgressRouter`) plus the wire fence tests in
`test/compliance/c4_blob.exs` (49 tests, 0 failures, 2026-10-18 re-measured via the compliance loader `mix test test/compliance_test.exs` -> 157 tests, 0 failures (16 excluded); lens-6 added the x-ms-range/Range precedence + ranged-HEAD courts, lens-5 added the request-id/conditional-write fence blocks, lens-7 added the verbatim-body leg, lens-8 added the emitted-marker round-trip court (emit -> resume -> terminate) and closed FINDING F1: success-path `x-ms-request-id` is now a v4 dashed GUID pinned by the full v4 regex at c4_blob.exs:85/:220).

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
| x-ms-date | UNSUPPORTED — `GAP(blob-x-ms-date-unvalidated)` (typed, close condition below) |
| Container PUT | CONFORMANT (re-graded 2026-10-15, V261014-13; see WIRE_PARITY.md:124 pins) |
| Container GET properties | CONFORMANT |
| comp=metadata PUT/GET | CONFORMANT |
| comp=lease | UNSUPPORTED — `GAP(blob-comp-lease-absent)` (typed, close condition below) |
| comp=list blobs XML | CONFORMANT (schema) / minor deviations |
| comp=list containers XML | CONFORMANT (schema) |
| Blob PUT | PARTIAL (octet-stream CONFORMANT; urlencoded/json DEV-MODE) |
| Blob GET (200/206/416) | CONFORMANT |
| Blob GET conditional (304) | CONFORMANT (re-graded 2026-10-15, V261014-13; see WIRE_PARITY.md:124 pins) |
| Blob DELETE | PARTIAL (202 shape; no x-ms-delete-type-permanent) |
| comp=immutabilityPolicy PUT | CONFORMANT (typed 400 on malformed; 200 + until on valid; fenced c4) |
| comp=immutabilityPolicy GET | PARTIAL — named divergence (JSON vs real XML envelope); tracked under the error-envelope family, not a separate open GAP token (V261014-13 implementer check) |
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

### x-ms-date — UNSUPPORTED (was GAP)

`GAP(blob-x-ms-date-unvalidated)` — UNSUPPORTED: `x-ms-date` is neither
required nor validated on blob routes (only `x-ms-version` presence is
enforced by the `blob_route` guard). Close condition: presence check + RFC
1123 parse + skew window shared with the other `:8443` planes (lane 06
receipt `06-blob-x-ms-date-unvalidated.md`).

Real service requires `x-ms-date` (or Date) for 2011-08-18+ versions and
rejects stale dates. smalt never reads `x-ms-date` anywhere on blob routes.
Typed-UNSUPPORTED for v26.10.14 (lane 06 §7): bounded future fix = presence
check + RFC 1123 parse + skew window shared with the other `:8443` planes.

### Container PUT — CONFORMANT (re-graded 2026-10-15, V261014-13)

The lens-5 work order landed and is pinned at WIRE_PARITY.md:124: container
PUT answers **201 with a quoted `ETag`, RFC 1123 `Last-Modified`,
`x-ms-request-id` + `x-ms-version`, and an empty body** (real-Azure shape;
`egress_router.ex` container PUT path). The historical GAP record below is
superseded (kept for replay).

_Historic (fixed):_ smalt (`egress_router.ex:683-689`) returned 201 with a
JSON body (the account/container record) and NO ETag/Last-Modified headers.
Live probe headers: `content-type: application/json`, no etag.
RE-WITNESSED lens-5 cycle 2 (fresh live probe: 201, no etag, no
last-modified, body `{"account":...,"immutable":true,...}`) — typed work
order delivered: `tmp/errc/compliance-corpus-lens5/work-order-container-put-headers.md`.

### Container GET properties — CONFORMANT

Real shape matched: 200 + `ETag`, `Last-Modified`, `x-ms-meta-*`,
`x-ms-has-immutability-policy` (exact `false` bytes), `x-ms-has-legal-hold`
(exact `false` bytes), `x-ms-request-id` (RFC 4122 v4 dashed GUID — **FINDING F1 CLOSED
(compliance lens-8 cycle 3, same-landing re-pin): the data-plane lane
landed `BlobStorage.request_id/0` (blob_storage.ex:999) and
`BlobService.request_id/0` as the same dashed-36 v4 form the ARM gateway
and LA surface emit; c4 courts pin the full v4 regex at the wire
(c4_blob.exs:85, :220), 30/0 green on the landed bytes), `x-ms-version` (`lib/smalt/data_plane/blob_service.ex:164-186`).
Live probe confirmed all seven header families present. HEAD container mirrors it
(egress_router.ex:899-922). Deviation: real `Last-Modified` is RFC 1123
(`Thu, 15 Oct 2026 04:50:47 GMT`); smalt emits ISO8601
(`2026-10-15T04:50:47.213Z`) — noted, not fenced.

Last-Modified format deviation (ISO8601 vs real RFC 1123) noted above;
otherwise shape-conformant.

### comp=metadata — CONFORMANT

PUT 200 + ETag; GET 200 + `x-ms-meta-*` headers
(`blob_service.ex:116-151`, egress_router.ex:670-681, 729-743). Round-trip
fenced in c4_blob.exs.

### comp=lease — UNSUPPORTED (was GAP)

`GAP(blob-comp-lease-absent)` — UNSUPPORTED: no `comp=lease` route exists;
`PUT ?comp=lease` falls through to the create-container branch (live probe of
lease-acquire → **201** with the container record body — silently
mis-interpreted, not refused). Close condition: full lease surface
(acquire/renew/change/release/break, `:smalt_blob_leases` table, enforcement
seam alongside `check_worm` in the `with` chains at `blob_storage.ex`
:131-135 and :263-267); until it lands
`<LeaseStatus>unlocked</LeaseStatus>` in container/blob listings is the
divergence marker (lane 06 §6).

Historic probe record: full `comp=lease` surface (acquire/renew/change/release/break,
`:smalt_blob_leases` table, enforcement seam alongside `check_worm` in the
`with` chains at `blob_storage.ex` :131-135 and :263-267) is feature-scale —
typed-UNSUPPORTED for v26.10.14 (lane 06 §6). No lease route exists; `PUT
?comp=lease` falls through to the create-container branch: live probe of
lease-acquire → **201** with the container record body — the request is
silently mis-interpreted as container creation instead of refused. Real: 201 +
`x-ms-lease-id` (or 409). The hardcoded `<LeaseStatus>unlocked</LeaseStatus>`
in container/blob listings stays as the divergence marker until the lease work
lands.

### comp=list blobs — CONFORMANT schema, minor deviations

XML skeleton `EnumerationResults[@ContainerName]/Blobs/Blob/Properties/{Name,
Content-Length, Etag, Last-Modified}` + `NextMarker` present/absent semantics
(`lib/smalt/data_plane/blob_storage.ex:302-346`), lexicographic order,
marker paging fenced over the wire in c4_blob.exs. Deviations: `Content-Type`
property never emitted (real always emits it). `<Prefix>` echo: the fast path
(no params) and the composed path now share the same echo expression
(v26.10.14 lane 06 defect 4 — previously the fast path interpolated the stored
key prefix directly).

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

### Blob GET conditional — CONFORMANT (re-graded 2026-10-15, V261014-13)

The RFC 7232 304 path landed and is pinned at WIRE_PARITY.md:124:
`get_blob_conditional/4` (`blob_storage.ex:479`) with full precedence —
If-Match mismatch → 412 `PreconditionFailed`, then If-None-Match match
(incl. `*` on an existing blob) → **304 empty-body with the ETag echoed**
(wired at `egress_router.ex:258-262` and `:1062-1088`). The historical GAP
record below is superseded (kept for replay).

_Historic (fixed):_ smalt's blob GET never evaluated If-None-Match (route at
egress_router.ex:829-874 had no conditional call;
`ConditionalHeaders.evaluate/2` supports `{:halt, 304}` —
`lib/smalt/data_plane/conditional_headers.ex:13-25` — but Cosmos was the only
caller). Live probe then: GET with matching If-None-Match → **200** (real:
304).

### Blob DELETE — PARTIAL

202 + `x-ms-request-id` + `x-ms-version` on success
(`blob_storage.ex:111-112`); 404 `BlobNotFound` exact code string; 409
`ContainerLocked` on WORM block. Real Delete Blob also emits
`x-ms-delete-type-permanent` — smalt does not. **FINDING F5 (lens-3 cycle 4)
— CLOSED (lens-5 cycle 1): `blob_error/3` LANDED at egress_router.ex:1605
(x-ms-request-id via `generate_request_id/0` v4 GUID + x-ms-version
"2021-12-02" over shared `send_json`), all blob error render sites routed
through it; the error-header court is fenced in c4_blob.exs and the
dropped-header mutant was KILLED (lens-5 cycle 1, 2 failures). Note (lens-8): success-path ids are now ALSO
v4 GUIDs — the lens-5-era success/error dialect divergence is closed.**

### comp=immutabilityPolicy PUT — CONFORMANT (re-graded 2026-10-15; was BUILD-BROKEN 500)

The wire path was rewritten (`immutability_policy_from_wire/1`, BodyCache raw
reader, typed 400 `InvalidXmlOrJson` on malformed bodies instead of the old
FunctionClauseError 500). Re-probed this cycle (c4 court, fresh run):
valid JSON policy → 200 + `x-ms-has-immutability-policy: true` +
`immutability-policy-until` header; empty body → 200 with NO until header;
malformed body → 400 `InvalidXmlOrJson`. All three legs fenced in
test/compliance/c4_blob.exs (immutabilityPolicy PUT tests), 18/0 green.
The historical defect record below is superseded (kept for replay).

_Historic (fixed):_ `Plug.Parsers` consumed the JSON body before `read_body`,
so `policy_from_wire/1` parsed `""` → empty policy; with `until` nil the
`put_resp_header(..., nil)` raised FunctionClauseError → 500.

### comp=immutabilityPolicy GET — PARTIAL (named divergence)

Real: 200 with XML `<ImmutabilityPolicy><ImmutabilityPeriodSinceCreationInDays>
30</...><ImmutabilityPolicyUntil>...</...></ImmutabilityPolicy>`. smalt returns
JSON `{"locked":false,"period_days":0,"until":null}` (egress_router.ex:697-711).
Snake_case JSON where the real service returns XML with PascalCase elements.

V261014-13 implementer check: this is a fifth blob divergence beyond the four
`WIRE_PARITY.md:124` tokens. Recorded as a named divergence inside the
error-envelope family record (not minted as its own open GAP token this
window — minting was deferred to the owning lane per V261014-13; the fix is
bounded: render the same XML envelope `blob_error_xml/4` already produces,
scoped to the immutabilityPolicy GET arm).

### comp=legalhold — PARTIAL

PUT 200 with `x-ms-has-legal-hold` header matches the real contract; smalt
additionally returns a JSON body `{"has_legal_hold":true}` (snake_case) where
the real service returns an EMPTY body (egress_router.ex:633-649). GET returns
`x-ms-legal-hold` header + empty body — conforms. Fenced in c4_blob.exs.

### Error envelope / code strings — PARTIAL

Codes CONFORMANT: `BlobNotFound`, `ContainerNotFound`, `ContainerLocked`,
`PreconditionFailed`, `InvalidRange`. Mismatches: `MissingXMsVersion` (real:
`MissingRequiredHeader`); `ImmutabilityPolicyNotFound`/`LegalHoldNotFound`
(egress codes) are not real Blob service error code strings.
**CLOSED (v26.10.14 lane 06)**: on the blob `comp=list` routes (container list
`GET /{account}?comp=list` and blob list `GET /{account}/{container}?comp=list`)
typed errors now emit the real-service XML envelope
`<?xml version="1.0" encoding="utf-8"?><Error><Code>...</Code><Message>...</Message></Error>`
with `Content-Type: application/xml` and the `x-ms-error-code` response header
(`blob_error_xml/4`, scoped to the comp=list arms only — every other
`blob_error/3` consumer keeps byte-identical JSON). All blob error responses
(JSON envelope included) now carry `x-ms-error-code` extracted from the body's
code slot (either envelope shape; no-code bodies emit no header). Also closed:
container-list `maxresults` split grammar — junk/zero/negative maxresults on
the container route answer typed 400 `InvalidQueryParameterValue`
(`BlobStorage.check_maxresults/1`), matching the blob route and real Azure.
Remaining: `comp=list` against a nonexistent container returns **200 empty
list** where real returns 404 `ContainerNotFound`.

comp=list on missing container → 200-empty (real: 404 ContainerNotFound).

### 409 vs 412 selection — CONFORMANT

409 `ContainerLocked` for WORM/lease-class conflicts; 412
`PreconditionFailed` for If-Match failures — matches the real service's
selection. Fenced (412 on stale If-Match, 409 on WORM delete).

### Delete precedence: WORM-vs-If-Match — DIVERGENCE (UNSUPPORTED v26.10.14)

`delete_blob/4` (`blob_storage.ex:263-267`) evaluates `check_worm` BEFORE
`check_if_match`: a blob that is BOTH WORM-locked (legal hold or locked
immutability policy) and If-Match-mismatched answers **409
`ContainerLocked`**. Real Azure evaluates preconditions (If-Match) FIRST and
answers **412 `PreconditionFailed`** for the same request pair.

Repro request pair (container WORM-locked, blob exists, stale If-Match):
`DELETE /{a}/{c}/{blob}` with `If-Match: "dead"` → smalt **409
`ContainerLocked`** / real **412 `PreconditionFailed`**. Same request with no
If-Match → both answer 409 `ContainerLocked`.

Typed-UNSUPPORTED for v26.10.14 (lane 06 §5): the reorder is contract-visible
(`test/data_plane/blob_hardening_test.exs` + the `delete_blob/4` `@doc` pin
409-on-WORM) and interacts with the future lease enforcement seam; revisit
with the lease work, which rewrites the same `with` chain.

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

## Lane 06 (v26.10.14) close-out notes

- **§1 XML escape astral parity — CLOSED.** `BlobService.xml_escape/1`
  delegates to `BlobStorage.xml_escape/1` (the divergent copy lacked the
  supplementary-plane numeric-character-reference transform — an astral
  container name enumerated with raw 4-byte UTF-8 is rejected by xmerl 2.x,
  `wfc_Legal_Character`). Fence: `mix test
  test/data_plane/blob_hardening_test.exs --only lane06`-class tests
  (`xml_escape/1 delegates`, astral container list + xmerl parse).
- **§2 maxresults grammar — CLOSED.** Container route routed through
  `BlobStorage.check_maxresults/1`; junk/zero/negative → 400
  `InvalidQueryParameterValue` (XML envelope on comp=list). Fence: container
  `?comp=list&maxresults=abc|0|-1|5x` → 400; `=5000`/absent → 200.
- **§3 XML error envelope + x-ms-error-code — CLOSED (§0 gate CLOSED).**
  Wire-court gate resolved empirically: cross-plane regression
  (`test/wire/egress_wire_test.exs`, `test/data_plane/cosmos_test.exs`,
  `test/data_plane/key_vault_actions_test.exs`,
  `test/data_plane/audit_planes_test.exs`,
  `test/security/security_hardening_test.exs`) → **288 tests, 0 failures**
  with zero non-blob JSON-shape changes. Fence: blob comp=list junk
  maxresults → 400 `application/xml` `<Error><Code>InvalidQueryParameterValue</Code></Error>`
  + `x-ms-error-code: InvalidQueryParameterValue`.
- **§4 fast-path prefix echo — CLOSED.** `render_blobs/9` → `render_blobs/10`
  now routes through the composed path's
  `if(prefix == "", do: key_prefix, else: prefix)` echo. Fence: plain
  `comp=list` `<Prefix>` identical to `prefix=""` composed-path request.

## Fence tests

`test/compliance/c4_blob.exs` — 14 wire tests over real Bandit/:httpc
sockets, fencing only CONFORMANT rows:

x-ms-version 400 guard, container properties header contract, metadata
round-trip, 404 ContainerNotFound, container+blob list XML schemas, blob PUT/
GET byte-exact round-trip + ETag, 206/416 range semantics, 404 BlobNotFound,
DELETE 202 shape, If-Match 412 + matched 201, WORM 409 ContainerLocked,
legal hold header contract, pagination NextMarker.

Result: `mix test test/compliance_test.exs` (compliance loader) → **157 tests, 0 failures (16 excluded)** (2026-10-18 re-measure; c4_blob register count fenced at 49 by the loader's inventory fence — 42 was the pre-lens-6/lens-5 count).

## Arcus re-anchor appendix (P3-L4, 2026-11-05)

Dual anchors per the C1-C7 re-anchoring plan (`docs/jira/v26.11.7/01-c1-c7-re-anchoring-plan.md`,
anchor form section): the smalt half is a COUNTERPART, not a successor; arcus line numbers
derived at execution time from the landed arcus tree. Per-anchor receipt:
`docs/jira/v26.11.7/receipts/p3-l4-c4-reanchor.md`.

| smalt locus (on-disk) | arcus counterpart (on-disk, real lines) | law |
|---|---|---|
| `lib/smalt/auth/bearer.ex:174-191` (SharedKey admit), `:198-209` (`shared_key_header?/1`) | `internal/dialect/azure/sharedkey.go:42-52` (`VerifySharedKey`), `:60-78` (`extract`), `:82-91` (`signatureOK`, constant-time) | SharedKey verification: `Authorization: SharedKey <acct>:<sig>` is a storage-client scheme; fail-closed; constant-time compare |
| `lib/smalt/data_plane/blob/core.ex:1859-1878` (`request_id/0`, re-exported `blob_storage.ex:158`), `lib/smalt/egress_router.ex:2722-2740` (`generate_request_id/0`) | `internal/dialect/azure/blob_headers.go:37-53` (`BlobRequestID`, v4 bits `:44-45`, dashed format `:46-52`) | KD-152/F1: `x-ms-request-id` dashed-36 RFC 4122 v4 GUID |
| `lib/smalt/data_plane/blob_service.ex:188-193` (`x-ms-version` emission) | `internal/dialect/azure/blob_headers.go:18-21` (`BlobVersionHeader`/`BlobAPIVersion` = `2021-12-02`), `:55-63` (`BlobBaseHeaders`) | every blob response carries x-ms-version: 2021-12-02 |
| `lib/smalt/data_plane/conditional_headers.ex:13-34` (`evaluate/2`) | `internal/dialect/azure/conditional_headers.go:35-77` (`EvaluateConditional`) | RFC 7232 §6 precedence: If-Match first/independent, 412; If-None-Match match -> 304 (GET/HEAD) / 412 |
| `lib/smalt/data_plane/conditional_headers.ex:50-62` (`etag_matches?/2`, `strip_quotes/1`) | `internal/dialect/azure/conditional_headers.go:79-101` (`etagListMatches`) | `*` / raw / quote-stripped candidate match over comma list |
| `lib/smalt/data_plane/blob/core.ex:1124` (`x-ms-range || range` precedence), `:1212-1229` (`parse_page_range/1`), `lib/smalt/data_plane/blob/leases.ex:605-638` (`parse_range/2`, guard bounds) | `internal/dialect/azure/blob_blocks.go:221-257` (`ParsePageRange`, `CheckPageAlignment`) | x-ms-range parse + 400 code strings + 512-byte alignment; the x-ms-range-over-Range *selection* is caller-side (dialect counterpart-absent, see below) |
| `lib/smalt/data_plane/blob/core.ex:405-430` (`check_block_id/1`, `block_key/4`) | `internal/dialect/azure/blob_blocks.go:41-70` (`ValidateBlockID`, `BlockKey`) | Put Block grammar: 1-64 bytes, base64, NUL-separated staged key |
| `lib/smalt/egress_router.ex:2829-2896` (`blob_error/3`, `put_error_code_header`, `blob_error_message`) | `internal/dialect/azure/errors_armwire.go:70-90` (`BlobRender`, `SendBlobError`) | blob-face XML `<Error>` envelope + x-ms-request-id/x-ms-version/x-ms-error-code stamping |
| `lib/smalt/data_plane/blob/core.ex:1583-1610` (`xml_escape/1`) | `internal/dialect/azure/errors_blob.go:9-48` (`XMLEscape`) | byte-exact XML escaping (control-byte drop, astral numeric refs) |
| `lib/smalt/data_plane/blob/core.ex:282-313` (metadata name/value validation) | `internal/dialect/azure/blob_headers.go:74-104` (`ValidateBlobMetadata`, `InvalidMetadataMessage`) | KD-141: C#-identifier names, control-free values, 400 InvalidMetadata |
| `lib/smalt/data_plane/blob_storage.ex:19-30` (per-blob immutability moduledoc), `lib/smalt/data_plane/blob/worm.ex:297-345` | `internal/dialect/azure/blob_headers.go:133-154` (`ParseWORMPolicyHeaders`) | mode-without-date 400, invalid date/mode 400 |
| `lib/smalt/data_plane/blob_service.ex:82-110` (list containers XML render), `:160-193` (metadata PUT + ETag) | `internal/dialect/azure/etags.go:22-34` (`StorageETag`, `ContainerETag`), `internal/dialect/azure/storage_host.go:24` (`storageVersion`) | quoted `0x`-prefixed ETag derivation; version pin |
| `lib/smalt/egress/storage_catch_all.ex` (batch grammar) | `internal/dialect/azure/blob_batch.go:40-190` (boundary/parts/sub-request/render law) | Put Blob Batch multipart grammar, 256 cap |
| `lib/smalt/data_plane/blob/core.ex:866-1010` (snapshot + DeleteSnapshots) | `internal/dialect/azure/blob_batch.go:191-260` (`SnapshotBlobHeaders`, `ParseDeleteSnapshots`, `CheckSnapshotsOnDelete`) | snapshot wire law + 409 SnapshotsPresent gate |
| `lib/smalt/egress_router.ex:2798-2814` (FEGS1 crash-fence fallback) | n/a — wire-layer crash fence stayed smalt-side; arcus dialect is pure functions | UNSUPPORTED(counterpart-absent), loud |

### Byte-pin receipts (read from disk 2026-11-05)

**x-ms-range precedence** — smalt `blob/core.ex:1124`:

    range = header_value(headers, "x-ms-range") || header_value(headers, "range") || ""

smalt `blob/leases.ex:608`: `Regex.run(~r/^bytes=(\d*)-(\d*)$/, String.trim(header))`.
arcus `blob_blocks.go:228-246` (`ParsePageRange`) pins the same parse + 400 code strings
(`MissingRequiredHeader` "x-ms-range is required for Put Page." /
`InvalidHeaderValue` "The x-ms-range value is invalid."). The x-ms-range-over-Range
*preference* is resolved engine-side in smalt (core.ex:1124); the arcus dialect exposes
the resolved header string, so the preference law is
UNSUPPORTED(counterpart-absent) at the dialect layer — loudly missing, not silently skipped.

**request-id v4 regex** — smalt mint `blob/core.ex:1865-1878` /
`egress_router.ex:2727-2740` (`~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b`, v4 bits
`c4 = band(c, 0x0FFF) + 0x4000`, `d = bor(band(d, 0x3FFF), 0x8000)`). smalt fence regex
`test/internal/kd_conf_court_test.exs:13`:
`~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/`.
arcus mint `blob_headers.go:39-53` (same v4 bit ops at `:44-45`); arcus fence
`blob_headers_test.go:15`:
`var dashed36 = regexp.MustCompile(`+"`"+`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`+"`"+`)`
with explicit v4 bit assertions at `blob_headers_test.go:26` ("is not version 4").

**verbatim body** — smalt `egress_router.ex:2858-2866` iolist envelope bytes:
`"<?xml version=\"1.0\" encoding=\"utf-8\"?>" <> "<Error><Code>" <> code <>
"</Code><Message>" <> ... <> "</Message></Error>"`. arcus `errors_armwire.go:75-78`
`BlobRender` concatenates the identical byte string (XMLEscape on both slots). The
FEGS1 fallback body (`egress_router.ex:2803`,
`<?xml version="1.0"...><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>`)
has no arcus counterpart (smalt-side crash fence).

### Stale smalt-side anchors (disclosed, not rewritten — plan law)

The C4_BLOB.md body anchors citing `blob_storage.ex:232-255 / 263-267 / 302-346 /
410-428 / 479 / 999` pre-date the T09 blob split: `blob_storage.ex` is now a 161-line
defdelegate facade and the cited law lives in `blob/core.ex`, `blob/leases.ex`,
`blob/worm.ex` (e.g. `blob_storage.ex:999` request_id is now `blob/core.ex:1865-1878`,
re-exported at `blob_storage.ex:158`). Per the plan ("the smalt anchor stays
byte-identical; the arcus half is appended, never substituted") the body text was NOT
rewritten; the on-disk loci above are the lawful re-anchor counterparts.

### Gate receipt

`go test ./internal/dialect/azure/` (arcus @ working tree 2026-11-05): **FAIL — 2
pre-existing failures, session-introduced = 0** (this lane edited docs only):
`TestFileShareListDir` (fileshare listing order) and `TestRoutingCourtAcrV2Route`
(ACR v2 base-ping grammar); both in files outside the C4 anchor set
(fileshare.go / routing). All blob/conditional/request-id/error-envelope laws PASS:
`TestBlobHeadersBlobRequestIDIsDashed36RFC4122v4`, `TestConditionalDateHeaders` (10
subtests), `TestConditionalNoLastModified`, `TestConditionalEmptyETag`, and the
`SendBlobError` courts. Targeted run
`-run 'TestBlobHeadersBlobRequestID|BlobError|ParsePageRange|Conditional'` → ok 0.285s.
