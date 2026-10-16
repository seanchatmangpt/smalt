# Receipt — V261014-06 (lane 06, Blob Storage hardening)

- **Subject:** `/Users/sac/smalt` @ `main` (working tree, no commits per lane contract)
- **Standing:** ALIVE (all fences executed and green on the edited tree)
- **Gate §0:** **CLOSED** — resolved empirically (see below).

## Files changed (all owned files, none of lane 19's regions)

- `lib/smalt/data_plane/blob_service.ex`
  - §1: `xml_escape/1` now delegates to `BlobStorage.xml_escape/1` (astral
    transform parity); `@doc`/`@spec` kept.
  - §2: `list_containers/2` routes through `BlobStorage.check_maxresults/1`
    (`with` guard; junk/zero/negative → `{:error, 400, "InvalidQueryParameter",
    msg}`); `list_containers_xml/2` passes the typed tuple through on error,
    keeps `{xml, next_marker}` on success (blob_service_test pin preserved,
    unchanged green). Renderer extracted to private `render_containers_xml/3`
    returning the xml string.
- `lib/smalt/data_plane/blob_storage.ex`
  - §4: fast path `render_blobs/9` → `render_blobs/10`; `<Prefix>` now emits
    via the composed path's `if(prefix == "", do: key_prefix, else: prefix)`
    expression.
- `lib/smalt/egress_router.ex` (blob route arms + funnel only)
  - Container `comp=list` arm: `case` over the engine result; typed error
    tuple → `blob_error_xml/4`.
  - Blob `comp=list` arm (~:910): typed error arm `blob_error` →
    `blob_error_xml/4`.
  - `blob_error/3`: additive `x-ms-error-code` header extracted from the
    body's code slot (`blob_error_code/1`, both envelope shapes; no-code
    bodies emit no header). JSON bodies byte-identical.
  - New `blob_error_xml/4`: `<?xml version="1.0" encoding="utf-8"?><Error><Code/><Message/></Error>`,
    `Content-Type: application/xml`, `x-ms-error-code` header.
- `test/data_plane/blob_hardening_test.exs`: new describe
  `lane 06 container-list hardening` — 6 tests (delegate parity, astral
  container list + xmerl parse, container maxresults 400/XML + 5000/absent
  200, blob comp=list 400 XML + header, prefix echo parity, non-list error
  keeps JSON + gains header).
- `docs/WIRE_PARITY.md` (blob row): `GAP(blob-error-envelope-json)` and
  `GAP(blob-x-ms-error-code-header-absent)` CLOSED; lease + x-ms-date rows
  rewritten as typed UNSUPPORTED with divergence markers; delete-precedence
  divergence (409-first vs 412-first) documented.
- `docs/compliance/C4_BLOB.md`: x-ms-date and comp=lease re-graded
  UNSUPPORTED; delete-precedence DIVERGENCE section with repro pair; Error
  envelope section close-out; lane 06 close-out notes with fence commands.

## §0 gate resolution

Implemented the scoped `comp=list` XML renderer + additive header. Cross-plane
regression run on the edited tree:

```
mix test test/wire/egress_wire_test.exs test/data_plane/cosmos_test.exs \
  test/data_plane/key_vault_actions_test.exs test/data_plane/audit_planes_test.exs \
  test/security/security_hardening_test.exs
→ 288 tests, 0 failures
```

No non-blob JSON changes (only additive response headers on blob-plane
errors). Gate: **CLOSE**. Typed-UNSUPPORTED fallback not needed.

## Verification (blob plane)

```
mix test test/data_plane/blob_hardening_test.exs test/data_plane/blob_service_test.exs
→ 109 tests, 0 failures   (blob_service_test unchanged green per §1 fence)
```

Concurrent-lane notes: egress_router.ex was overwritten once mid-flight by a
lane 19 write (my edits lost); re-applied against the then-current on-disk
state. Shared-tree compile breaks in `cosmos.ex` and
`messaging/amqp/management_rpc.ex` (other lanes' in-flight edits) were waited
out, not touched.

## UNSUPPORTED dispositions (documented, not implemented)

- §5 delete precedence WORM-vs-If-Match (409-first vs real 412-first):
  contract-visible reorder, revisit with the lease work.
- §6 `comp=lease` full surface: feature-scale; `<LeaseStatus>unlocked</LeaseStatus>`
  stays as divergence marker.
- §7 `x-ms-date` validation: see receipts/06-blob-x-ms-date-unvalidated.md.

## Falsifiers

- Reverting `blob_error_xml/4` to `blob_error` in either comp=list arm must
  fail the lane 06 wire tests (400 JSON instead of XML).
- Reverting the `check_maxresults` `with` guard in `list_containers/2` must
  fail the container junk-maxresults 400 tests.
- Replacing `BlobService.xml_escape/1` delegation with the old copy must fail
  the astral container-list test (xmerl `wfc_Legal_Character`).
