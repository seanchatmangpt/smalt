# w6c — Certificate issuers + contacts (Azure KV REST parity)

**Standing:** ALIVE (real-wire witness over a private lane substrate, block v62)

Lane: wave-6 / w6c · 2026-10-20 · surface: `lib/smalt/data_plane/certificates.ex`
(+`lib/smalt/egress_router.ex` `@non_blob_put_namespaces` entry, disclosed)

## What landed

Azure KV certificate-ISSUERS + certificate-CONTACTS faces on the KD-104
certificates plane, in `lib/smalt/data_plane/certificates.ex`:

- **Issuers CRUD** — `put_issuer/3` (PUT /certificates/issuers/:name,
  create-or-replace, `provider` required → typed 400 BadRequest; full-replace
  semantics with `created` preserved / `updated` re-stamped; `pwd` stored but
  never echoed — write-only, real-service parity), `get_issuer/1`,
  `delete_issuer/1` (200 echo then gone; typed `404 IssuerNotFound`), and
  the `{"value": [{"id","provider"}]}` CertificateIssuerItem list envelope
  via `list_issuers/0` (walks `list_all/1` for tuple-keyed rows, `is_issuer`
  flag-filtered — the binary-key `Store.list/1` contract would silently drop
  tuple rows, same class as the deleted-certificates list fix).
  Storage: `{:issuer, name}` tuple keys in the SAME heir'd
  `:smalt_vault_certificates` table (no new table; no owner GenServer).
  Routes ride the w6R router restructure (`lib/smalt/egress/KvRoutes.ex`),
  placed before the `/certificates/:name` catch-alls in definition order
  (catch-all placement law).

## Witness (real wire, block v62, MIX_BUILD_ROOT=_build-lane-w6c)

`W6C WITNESS: 0 fails` / `WITNESS_VERDICT=PASS` — 28/28 checks:

```
PASS provider echoed / pwd write-only / account_id echoed
PASS replace 200, replace clears credentials, created preserved
PASS issuers list has row ({"id","provider"} envelope)
PASS GET issuer 200, GET provider self, GET pwd write-only
PASS DELETE issuer 200 then GET 404
PASS GET contacts unset 404 + ContactNotFound code
PASS PUT contacts 200 + echo, GET 200 + echo (persistence across requests)
PASS GET contacts 200 + echo (persistence across requests)
PASS empty provider 400 + BadRequest code
PASS empty contacts 400
PASS missing email 400
PASS unknown issuer 404 + IssuerNotFound code
PASS DELETE unknown issuer 404
PASS PUT issuer 200 (parity shape: id/issuer/provider/credentials/organization_details/attributes)
```

## Gates (real output)

- `MIX_BUILD_ROOT=_build-lane-w6c mix compile --warnings-as-errors` — my two
  files are warning-free; residual warnings are other lanes' in-flight debt
  (110 warnings, none in w6c's files). Compile of the TREE green 08:32:05 /
  08:41:57 (full compile green, zero errors; warnings-only failure only under
  --warnings-as-errors from foreign files).
- `MIX_BUILD_ROOT=_build-lane-w6c mix test test/internal` — **48 tests, 0 failures**
  (incl. KD-104 pending-face regression).
- Substrate: v62 ports 40320-40325, auth :enforce (STS bearer), torn down
  clean (sweep) at witness exit.

## Disclosures

- Shared-seam edit: `@non_blob_put_namespaces ~w(dbs certificates)` — the file's
  own whitelist law (comment block above the attribute) mandates the entry for
  any literal 3-segment PUT route; without it the issuer PUT body is treated as
  raw blob content and the route's with_valid_body gate answers 400 InvalidBody
  (measured, not inferred: dbg3 PUT 200 after the fix, 400 before).
- Minimal unblock attempt on blob_storage.ex:2802 was a no-op (the owning lane
  had already self-fixed concurrently) — net edit: NONE (disclosed attempt only).
- Compile-freeze observations, no fixes applied (owners self-fixed): imds.ex,
  file_share.ex, cosmos_authz.ex, deployments.ex, dns.ex, rbac.ex, key_vault_actions.ex,
  appconfig_features.ex, blob_soft_delete.ex, key_vault_actions.ex:1940,
  110 warnings in foreign files.
- Route-block relocation: my routes were moved verbatim into
  `lib/smalt/egress/KvRoutes.ex` by the w6R router-restructure lane
  (679+/1694-) mid-lane — my on-disk edits landed in the new shape on second
  landing (routes verified in the compiled beam via `strings`).

## Notes (out of scope, one sentence each)

- w6o's `file_share_plane` plug (landed mid-lane) shadows ALL multi-segment
  GET/DELETE without file-plane query shapes: GET /keys/:name (3-seg) answers
  blob XML 404 on the 08:41 beam — pre-existing/foreign lane defect, measured
  on v62: GET /keys/dbg-k → 404 XML ResourceNotFound.
- STS tenant path: any tenant segment works (1273-char bearer, HS256-class).
