# 01-c1-c7-re-anchoring-plan

Standing: UNVERIFIED (plan; every anchor below stays UNVERIFIED until its
per-anchor receipt exists — charter §4.3: "a re-anchor with no receipt is
UNVERIFIED and blocks landing").

Scope: P3 of `00-azure-out-migration-charter.md` — re-anchor the seven
consumer compliance docs in `docs/compliance/` (C1-C7) after the dialect
layer lands in arcus `internal/dialect/azure/`. This file is a PLAN only;
the C1-C7 docs themselves are post-decision work and are NOT edited by
this wave.

## Anchor form (per the sigv4/KD-212 precedent)

Dual anchor, file-pair form already witnessed in
`docs/jira/v26.11.6/KNOWN_DIVERGENCES.md` rows KD-212 and KD-SIGV4-1/-2:

    smalt <lib-path>:<lines> <-> arcus internal/dialect/azure/<file>.go:<lines>

Rules:

- Every existing bare `file.ex:N` locus inside a C-doc gains an arcus
  counterpart anchor in the same line / same table cell.
- The arcus file is a COUNTERPART, not a successor (KD-212 language): no KD
  flip is implied by the re-anchor itself.
- The smalt anchor stays byte-identical; the arcus half is appended, never
  substituted. If P4 strip later removes the smalt half, that is a separate
  receipted transition.
- Exact arcus line numbers are derived at execution time from the landed
  arcus tree and pinned in the per-anchor receipt; this plan pins the
  file-level mapping only (arcus file existence verified on disk for every
  counterpart named below, 2026-11-05).

## Locus inventory

Method: every C-doc line carrying a `file.ex:N`-style code anchor was
enumerated with
`grep -nE "[a-z_0-9]+\.(ex|exs|go|erl):[0-9]"`. Doc-line numbers below are
line numbers inside the C-doc itself.

### C1_ARM_REST (19 loci)

Smalt subject: `lib/smalt/arm_gateway/router.ex` + `lro.ex` +
`lro_sweeper.ex` + `provider_matrix.ex` (doc lines 7-8).

| doc-line | smalt anchor | arcus counterpart |
|---|---|---|
| 39 | `router.ex:531-560` send_arm_error/4 | `errors_armwire.go` |
| 42 | `router.ex:660-671`, `:1075-1084` envelope | `gateway.go` |
| 44 | `router.ex:805-874`, `:618-677` sync PUT | `gateway.go` |
| 45 | `router.ex:860-872` cond, `:2139-2146` headers | `lro.go` |
| 46 | `router.ex:2139-2146` async headers | `lro.go` |
| 47 | `router.ex:708` RG delete LRO | `lro.go` |
| 48 | `router.ex:2607` poll; `lro.ex:378-423`; `lro_sweeper.ex:73-88` | `lro.go` |
| 49 | `lro.ex:378-423`, `:70-107`, `:323` | `lro.go` |
| 50 | `router.ex:1923-1936`, `:1947-1949` api-version | `apiversion.go` |
| 52 | `router.ex:1985-1991` latest-version msg | `apiversion.go` |
| 53 | `router.ex:2630-2651` segment case | `arm_path.go`, `entitypath.go` |
| 54 | `router.ex:2124-2128` provider downcase | `arm_path.go`, `provider_matrix.go` |
| 55 | `router.ex:433-452`, `:609-616`, `:411` LIST | `gateway.go` |
| 58 | `router.ex:53,101,53-54` request-id plug | `gateway.go` |
| 59 | `router.ex:54,132` throttle plug | `gateway.go` |
| 60 | `router.ex:186` content-type | `gateway.go` |
| 90 | `lro.ex:378-423` defect ledger closure | `lro.go` |
| 135 | `lro.ex:378-423` prose restatement | `lro.go` |
| 139 | `lro_sweeper.ex:73-88` prose restatement | `lro.go` |

### C2_KEYVAULT (14 loci) — AFFECTED; task premise REFUTED

C2 exists (`docs/compliance/C2_KEYVAULT.md`) and is in scope: its loci pin
`lib/smalt/data_plane/key_vault_actions.ex`, `lib/smalt/data_plane/skr.ex`,
`lib/smalt/security/attestation.ex`, `lib/smalt/egress_router.ex`; arcus
already carries `kv7.go` (315 lines), `attestation.go` (801 lines),
`armkv.go` on disk. The premise "C2 apparently doesn't exist or is
unaffected" is REFUTED by on-disk evidence.

| doc-line | smalt anchor | arcus counterpart |
|---|---|---|
| 30 | `key_vault_actions.ex` actions row | `kv7.go` |
| 36 | `key_vault_actions.ex:113-122` | `kv7.go` |
| 37 | `key_vault_actions.ex:157-167` | `kv7.go` |
| 38 | `key_vault_actions.ex:176-190` | `kv7.go` |
| 39 | `key_vault_actions.ex:452-483` | `kv7.go` |
| 41 | `key_vault_actions.ex:508-535` | `kv7.go` |
| 42 | `key_vault_actions.ex:548` | `kv7.go` |
| 45 | `skr.ex:55-67` | `kv7.go` |
| 46 | `skr.ex:84-101` | `kv7.go` (SKR leg: verify at receipt) |
| 47 | `skr.ex:106-168` | `kv7.go` (SKR leg: verify at receipt) |
| 48 | `skr.ex:176-204` | `kv7.go` (SKR leg: verify at receipt) |
| 50 | `skr.ex:353-380` | `kv7.go` (SKR leg: verify at receipt) |
| 51 | `attestation.ex:28` | `attestation.go` |
| 53 | `egress_router.ex:475-535`, `:486`, `:669-690` | `armkv.go`, `gateway.go` |

### C3_COSMOS (11 loci)

Smalt subject: `lib/smalt/data_plane/cosmos.ex`,
`partition_key.ex`, `cosmos_sql.ex`, plus `lib/smalt/egress_router.ex`
(doc lines 7-10).

| doc-line | smalt anchor | arcus counterpart |
|---|---|---|
| 10 | `egress_router.ex:125-289,565-597,954-990,1311-1327` | `gateway.go` |
| 48 | `cosmos.ex` route row | `gateway.go` |
| 49 | `egress_router.ex:249-256` | `gateway.go` |
| 53 | `cosmos.ex:1356` | `gateway.go` |
| 55 | `egress_router.ex:966-990` | `gateway.go` |
| 57 | `egress_router.ex:954-963` | `gateway.go` |
| 58 | `cosmos.ex:213`, `:226` | `gateway.go` |
| 59 | `egress_router.ex:1311-1327`, `:1361-1373` | `gateway.go` |
| 66 | `cosmos.ex:417-445`, `:465-478`, `:480`, `:484-490` | `gateway.go` |
| 72 | `cosmos.ex:519-521`, `:557`, `:590-604`, `:652-670` | `gateway.go` |
| 81 | `cosmos.ex:98-121` throttle; `cosmos_sql_test.exs:88` | `gateway.go` |

Note: arcus `cosmos_auth.go` (58 lines) covers the auth header scheme; the
SQL/query-engine loci have NO arcus counterpart file yet — those anchors
land as file-level `gateway.go` only if the wire shape actually migrated;
receipts must state UNSUPPORTED(counterpart-absent) where the law did not
travel. This is the plan's largest open risk.

### C4_BLOB (29 loci)

Smalt subject: `lib/smalt/data_plane/blob_storage.ex`, `blob_service.ex`,
`blob_error.ex`, `conditional_headers.ex` (data_plane), and
`lib/smalt/egress_router.ex`, `lib/smalt/auth/bearer.ex` (doc lines 12-15).

| doc-line | smalt anchor | arcus counterpart |
|---|---|---|
| 6 | header/subject row | n/a (subject line, no arcus pair) |
| 50 | `bearer.ex:40-48` SharedKey enforce | `sharedkey.go` |
| 51 | `egress_router.ex` probe row | `storage_host.go` |
| 52 | `egress_router.ex:1005-1026` probe | `storage_host.go` |
| 62 | bearer auth row | `sharedkey.go` |
| 64 | bearer auth detail | `sharedkey.go` |
| 89 | `egress_router.ex:821` (x2 in line) | `blob_headers.go` |
| 102 | blob headers row | `blob_headers.go` |
| 105 | `blob_storage.ex:19-20` | `blob_headers.go` |
| 107 | `blob_storage.ex:111-112` | `blob_headers.go` |
| 117 | `conditional_headers.ex:13-25` | `conditional_headers.go` |
| 147 | `blob_storage.ex:232-255` | `blob_headers.go` |
| 159 | `blob_storage.ex:263-267` | `blob_headers.go` |
| 168 | `blob_storage.ex:302-346` | `blob_headers.go` |
| 172 | `blob_storage.ex:410-428` | `blob_headers.go` |
| 175 | `blob_storage.ex:479` | `blob_headers.go` |
| 180 | `blob_storage.ex:999` | `blob_headers.go` |
| 181 | lease row | `leases.go` |
| 187 | immutability/WORM row | `leases.go` (verify at receipt) |
| 190 | batch row | `blob_batch.go` |
| 194 | `egress_router.ex:633-649` | `blob_headers.go` |
| 196 | `egress_router.ex:670-681` | `blob_headers.go` |
| 203 | `egress_router.ex:683-689` | `blob_headers.go` |
| 206 | `egress_router.ex:697-711` | `blob_headers.go` |
| 232 | `egress_router.ex:829-874` (x2) | `blob_headers.go` |
| 246 | `egress_router.ex:899-922` | `blob_headers.go` |
| 280 | `blob_service.ex:68-106` | `storage_host.go` |
| 300 | `blob_service.ex:164-186` | `storage_host.go` |
| 306 | `c4_blob.exs:85`, `test.exs:7` fence pins | `blob_headers_test.go` |
| — | error envelope legs | `errors_blob.go` (KD-212 pair witness) |
| — | `egress_router.ex:1605` | `blob_headers.go` |

### C5_SERVICEBUS (16 loci)

Smalt subject: `lib/smalt/messaging/amqp/{connection,frame_codec,
primitive_codec,delivery_encoder,queue_store}.ex` (doc lines 19-37).

| doc-line | smalt anchor | arcus counterpart |
|---|---|---|
| 19 | `connection.ex:130-140` | `sb_rest.go` (verify at receipt) |
| 20 | `connection.ex:371-380` | `sb_rest.go` |
| 21 | `connection.ex:404-416` | `sb_rest.go` |
| 22 | `connection.ex:481` | `sb_rest.go` |
| 23 | `connection.ex:517-532` | `sb_rest.go` |
| 24 | `connection.ex:566` | `sb_rest.go` |
| 25 | `connection.ex:770-780` | `sb_rest.go` |
| 26 | `connection.ex:795` | `sb_rest.go` |
| 28 | `connection.ex:962-969` | `sb_rest.go` |
| 29 | `connection.ex:1340` | `sb_rest.go` |
| 31 | `connection.ex:1402-1445` | `sb_rest.go` |
| 32 | `connection.ex:2260` | `sb_rest.go` |
| 33 | `frame_codec.ex:69-73` | `sb_rest.go` (verify at receipt) |
| 35 | `frame_codec.ex:159-164`, `:264-277`, `:316-330` | `sb_rest.go` |
| 36 | `frame_codec.ex:486-506`, `:535-543` | `sb_rest.go` |
| 37 | `primitive_codec.ex:170-190`, `:454-472`;
`delivery_encoder.ex:124`, `:131-133` | `sb_rest.go` |

Note: the AMQP frame/transfer-layer laws may NOT have traveled to arcus
(the landed `sb_rest.go`, `cbs.go`, `amqp_annotations.go`,
`entitypath.go`, `queue_rest.go` set is REST-shaped). Every C5 anchor
whose arcus counterpart is absent at execution lands
UNSUPPORTED(counterpart-absent) in its receipt — loudly missing, never
silently skipped.

### C6_OAUTH_OIDC (10 loci)

Smalt subject: `lib/smalt/arm_gateway/router.ex` (STS/OIDC legs) +
`lib/smalt/auth/bearer.ex` (doc line 105-106 states the locus basis).
Arcus counterparts on disk: `oidc_sts.go` (465 lines),
`oidc_discovery.go`, `oidc_sts_test.go`, `errors_aad.go`.

| doc-line | smalt anchor | arcus counterpart |
|---|---|---|
| 30 | `router.ex` token endpoint row | `oidc_sts.go` |
| 35 | `router.ex` tenant path row | `oidc_sts.go` |
| 36 | `router.ex` common-tenant row | `oidc_sts.go` |
| 43 | `router.ex` RFC 7519 claims row | `oidc_sts.go` |
| 44 | `router.ex` Azure claims row | `oidc_sts.go` |
| 45 | `router.ex` fixed claim values row | `oidc_sts.go` |
| 53 | `router.ex` discovery endpoints row | `oidc_discovery.go` |
| 59 | `router.ex` tenant_discovery wiring | `oidc_discovery.go` |
| 65 | `router.ex` enforce 401 row | `errors_aad.go` |
| 72 | `router.ex:2430`, `:2530-2545`, `:290-315`, `:291-304`,
`:299-304`, `:390-400`, `:42-46`; `bearer.ex:565` | `oidc_sts.go` |

### C7_EVENT_PLANES (8 loci)

Smalt subject: `lib/smalt/egress_router.ex`,
`lib/smalt/messaging/event_stream.ex`, `event_hubs.ex`,
`lib/smalt/data_plane/{sentinel,purview_atlas,resource_graph}.ex`.

| doc-line | smalt anchor | arcus counterpart |
|---|---|---|
| 19 | `event_stream.ex:30-47`, `:131-137` | `event_grid.go` |
| 21 | `event_hubs.ex:62` (+ `:75`, `:451` refs) | `event_grid.go` (verify at receipt) |
| 23 | `sentinel.ex` DCR ingest | `monitor.go` |
| 28 | `purview_atlas.ex:22-36`, `:53-79` | `sentinel_purview.go` |
| 29 | `resource_graph.ex` row | `provider_matrix.go` (verify at receipt) |
| 34 | Event Hubs row | `event_grid.go` (verify at receipt) |
| 35 | Event Grid row | `event_grid.go` |
| 69 | `egress_router.ex:1199` | `event_grid.go` |

## Receipt requirement per anchor

Each re-anchored locus gets ONE receipt row in a per-C-doc receipt file at
`docs/jira/v26.11.7/receipts/p3-reanchor-<Cn>.md`, fields:

1. `locus`: C-doc path + doc-line number from the tables above.
2. `smalt anchor`: the existing `file:lines` pin, quoted byte-identical
   (untouched smalt half).
3. `arcus anchor`: `internal/dialect/azure/<file>.go:<lines>` derived at
   execution from the landed arcus tree — line numbers REQUIRED, not
   file-level.
4. `verdict`: PASS (counterpart found + line pinned) |
   UNSUPPORTED(counterpart-absent) (law did not travel; loudly missing,
   never silently skipped) | BLOCKED (counterpart ambiguous, e.g. the C5
   AMQP frame layer or C3 SQL engine — name the ambiguity).
5. `sha256`: of the arcus counterpart file at pin time (Byte-Identity
   Guard input, per charter §5 P0 pattern).
6. `Standing:` line per `[[receipt-standing-law]]` — closed vocabulary
   only.

Closure condition: all loci in the tables above have receipt rows with
verdict PASS or a typed UNSUPPORTED/BLOCKED; zero silently-missing cells.
Doc-level completion receipt then lands at
`docs/jira/v26.11.7/receipts/p3-reanchor-summary.md` with the locus count
re-read from the receipt files, not from this plan.

## Receipt (this plan)

- File: `/Users/sac/smalt/docs/jira/v26.11.7/01-c1-c7-re-anchoring-plan.md`
  (new; sole owned file; no C-doc edited; no git operations).
- Locus count: 19 + 14 + 11 + 29 + 16 + 10 + 8 = **107 loci** across 7 docs
  (C2 included — its doc exists and is affected; task premise refuted
  on-disk).
- Evidence: locus lines enumerated by grep over `docs/compliance/` on
  2026-11-05; arcus counterparts verified present in
  `/Users/sac/arcus/internal/dialect/azure/` (kv7, attestation, armkv,
  cosmos_auth, sb_rest, event_grid, oidc_sts, oidc_discovery, errors_aad,
  errors_armwire, errors_blob, lro, apiversion, arm_path, entitypath,
  gateway, provider_matrix, sharedkey, blob_headers, conditional_headers,
  blob_batch, leases, storage_host, monitor, sentinel_purview — all
  present on disk).
