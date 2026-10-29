# KD Register Integration 2026-10-24

Upstream defect handoff from the upstream security-claim courts (17-court corpus,
commit 014a973) to the smalt substrate owner. Each row names the substrate
file/behavior, the exact witnessed evidence, and a suggested fix. Court sources
live in `<upstream-checkout>/playground/test/security-claims/`.

## Rows

### KD-R17-1: wrong-pk DELETE destroys cross-partition

- Surface: `lib/smalt/data_plane/cosmos.ex` — `delete_doc/4` /
  `do_delete_doc/4`, keyed only on `doc_key(db, coll, doc_id)`.
- Divergence: a DELETE carrying a foreign `x-ms-documentdb-partitionkey`
  header answers 204 and really destroys the document. Real Cosmos answers
  404 ("partition key ... doesn't match") and destroys nothing.
- Evidence: upstream court
  `playground/test/security-claims/s06-s07-acl-rls.court.test.ts`, S7.5
  (witness): firm-B-keyed DELETE of firm-A's doc answered `HTTP 204` and the
  firm-A partition count after the delete was `0`.
- Suggested fix: thread the parsed partition key (see
  `lib/smalt/data_plane/partition_key.ex`) into `do_delete_doc/4`; before
  `Store.delete`, compare the header pk against the stored doc's pk and
  return `error_response(db, coll, 404, "NotFound", ...)` on mismatch —
  matching the real-Cosmos message already asserted in S7.3:
  "Partition key provided in the header doesn't match the partition key of
  the document".

### KD-R17-2: point-read ignores the partition-key header

- Surface: `lib/smalt/data_plane/cosmos.ex` — point-read path (docs GET by
  id): the `x-ms-documentdb-partitionkey` header is not consulted.
- Divergence: a GET carrying a foreign pk answers 200 with the document
  body. Real Cosmos answers 404 on pk mismatch. RLS holds on the query
  surface and the write fence, but any caller that can name a doc id can
  point-read across partitions (leak surface).
- Evidence: upstream court `s06-s07-acl-rls.court.test.ts`, S7.4 (witness):
  firm-B-keyed GET of firm-A's doc answered `HTTP 200` with
  `id=<DOC_A>, pk=<FIRM_A>`; contrast S7.3, where the same mismatch on the
  write fence correctly answers 400 BadRequest with the real-Cosmos message.
- Suggested fix: apply the same pk-match check as the write fence (S7.3
  path) on the point-read path: header pk present and != stored doc pk ->
  404 NotFound, no body.

### KD-R17-3: keyvault "latest" is not last-write

- Surface: `lib/smalt/data_plane/key_vault_actions.ex` +
  `lib/smalt/egress/KvRoutes.ex` — secrets store keeps one row per bare
  name; "latest" (version-omitted GET) resolves by version id, not by
  write order.
- Divergence: "latest" resolves as the lexically-greatest version UUID, not
  the last-written version. Witnessed: after a 3rd PUT of a secret, latest
  stayed on the lexically-greater (earlier) version id. Real Azure resolves
  latest as the most recently created version.
- Evidence: upstream court
  `playground/test/security-claims/s19-key-rotation.court.test.ts`, S19.3
  (substrate observation comment, lines 147-156): "latest resolution over
  multiple versions is the lexically-greatest version UUID"; the court had
  to relax to "latest resolves to a version created in this court".
- Suggested fix: stamp each version row with a monotonic `created` timestamp
  (or keep a `latest` pointer in the bare-name record at write time, the
  way re-PUT/rotate already overwrite); resolve version-omitted GET by that
  ordering, never by comparing version-id strings.
- STATUS 2026-10-25: closed upstream — fix landed in
  `lib/smalt/egress/KvRoutes.ex` (version rows, commit-pending in the smalt
  working tree); upstream courts s19/s10 witnessed on the wire (s19 4/4,
  s10 4/4, 2026-10-25T06:05Z session), see upstream
  `docs/verification/kd-register.md` rows KD-S3/KD-S4 and
  `docs/verification/register-federation-witness.md`.

### KD-R17-4 (note): superseded-version addressability is environment-dependent

- Not a defect row — a law that must stay disjunctive. The two courts
  disagree because the substrate behind them differs:
  - `s10-byok.court.test.ts` S10.3 (live probe 2026-10-24): superseded
    version id answers `404` on the smalt wire — "substrate serves ONLY the
    latest version" (asserted, registered divergence from real Azure's
    retained version history).
  - `s19-key-rotation.court.test.ts` (lines 118-138): a superseded version
    REMAINS exactly addressable and keeps its value (`200`,
    "superseded version keeps its value").
- Consequence: any consumer claim pinned to "superseded versions are (or
  are not) addressable" must be stated as
  `addressable-on-live | 404-on-wire` (both typed), not as a fixed law.
  Resolution depends on which substrate generation the court runs against;
  fix KD-R17-3 (stable latest resolution) is a precondition for collapsing
  this to one behavior.
- Pinning courts: `s10-byok.court.test.ts` S10.3 vs
  `s19-key-rotation.court.test.ts` superseded-read leg.
- STATUS 2026-10-25: closed upstream — the substrate now retains version
  history in `lib/smalt/egress/KvRoutes.ex` (commit-pending in the smalt
  working tree); superseded version ids answer 200 with retained values.
  Disjunctive law collapses to one behavior. upstream courts s19/s10 witnessed
  on the wire 2026-10-25T06:05Z (s19 leg 2 asserts both latest and
  superseded 200; s10 leg 3 same), see upstream
  `docs/verification/kd-register.md` rows KD-S3/KD-S4 and
  `docs/verification/register-federation-witness.md`.

### KD-R17-5 (V20a): versions-list bundles dropped the `version` member

- Surface: `lib/smalt/egress/KvRoutes.ex` — `get "/secrets/:name/versions"`.
- Divergence: the list face projected each retained version row through
  `public_secret_record/1`, which drops the documented SecretBundle
  `version` member — every upstream s19 (2b) / s10.4 bundle read
  `bundle.version === undefined`. Real Azure answers `version` on every
  entry of Get Secret Versions (Microsoft Learn, KV 7.4).
- Evidence: upstream courts
  `playground/test/security-claims/s19-key-rotation.court.test.ts` S19 2b
  and `s10-byok.court.test.ts` S10.4 (newest-first + `version` member
  assertions) vs. the smalt wire.
- Fix (V20a): the versions-list face now projects with
  `Map.drop(row, ["versions", "created_seq", "is_version_row"])` —
  `version` and `value` ride every bundle; the KD-S3 internal bookkeeping
  still never leaves the vault. Point faces are untouched
  (`public_secret_record/1` unchanged, home-tenant bytes unchanged).
- Fix (V20b, post-restart falsifier): the SecretBundle `id` leaked the
  internal scoped storage key — a foreign-`tid` caller (upstream's mint
  authority `/organizations`) saw
  `https://{host}/secrets/{tid}/{name}/{version}`, failing s19:153
  ("bundle id names the secret + version"). The PUT now stores under the
  scoped key but builds the stored id from the UNSCOPED route name —
  tenant identity rides the bearer, never the URL path. Home-tenant ids
  byte-identical; foreign ids match the documented
  `https://{host}/secrets/{name}/{version}` shape. The fence leg asserts
  the id names the secret and carries no `/t1/` segment.
- Gate: `test/integration/tenant_fence_blob_kv_queue_test.exs` extended
  with the versions-list fence leg (owner list = 3 bundles newest-first
  byte-exact values incl. the `version` member; foreign versions probe ->
  403 Forbidden with owner history intact; no-tid home round trip on
  legacy keys 3-newest-first; foreign list fenced from home 403) —
  `mix test test/internal/kdlith_w2_versions_list_test.exs
  test/integration/tenant_fence_blob_kv_queue_test.exs` = 6 passed.
- STATUS 2026-10-25: closed in the smalt working tree (commit-pending);
  upstream s19/s10 courts flip at the coordinator substrate restart.

## Court provenance

- `<upstream-checkout>/playground/test/security-claims/s06-s07-acl-rls.court.test.ts` (S7.3-S7.5)
- `<upstream-checkout>/playground/test/security-claims/s10-byok.court.test.ts` (S10.3)
- `<upstream-checkout>/playground/test/security-claims/s19-key-rotation.court.test.ts` (S19, lines 111-156)

## See Also

- upstream `docs/verification/kd-register.md` (consumer-side register)
