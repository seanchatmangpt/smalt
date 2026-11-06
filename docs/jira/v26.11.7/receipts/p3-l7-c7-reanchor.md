# P3-L7 — C7 event planes re-anchor receipt

Standing: PARTIAL_ALIVE

Lane P3-L7 of `docs/jira/v26.11.7/01-c1-c7-re-anchoring-plan.md` (C7_EVENT_PLANES,
8 loci + provenance re-point). Dual anchors appended to
`docs/compliance/C7_EVENT_PLANES.md` (new "Arcus dual anchors" section; the
pre-existing smalt pins and rows are byte-identical — verified by the append-only
edit shape). Line numbers below derived at execution time from the landed arcus
tree at `/Users/sac/arcus`. No git actions taken.

## Locus rows

| # | locus (C7 doc line) | smalt anchor (unchanged) | arcus anchor (pinned at execution) | verdict |
|---|---|---|---|---|
| 1 | C7_EVENT_PLANES.md:16 (C7-1a structured mode, 200-empty) | `lib/smalt/egress_router.ex` route + `event_stream.ex` publish | `internal/dialect/azure/event_grid.go:131-181` `BuildEnvelope`; `:202` `DefaultRetryPolicy` | PASS |
| 2 | C7_EVENT_PLANES.md:18 (C7-1c binary-mode ce-* headers) | `binary_mode_headers?/1`, `binary_mode_event/2` (egress_router) | `internal/dialect/azure/webpubsub_faces.go:241-257` `WebPubSubCloudEventHeaders` | PASS |
| 3 | C7_EVENT_PLANES.md:19 (C7-1d REQUIRED attrs + id auto-stamp) | `lib/smalt/messaging/event_stream.ex:30-47`, `:131` (`event_id/1`) | `internal/dialect/azure/event_grid.go:25-37` `ValidateSchema`; `:131-181` `BuildEnvelope` | PASS |
| 4 | C7_EVENT_PLANES.md:21-23 (C7-2a/b/c EH sequence, receive, partitions) | `lib/smalt/messaging/event_hubs.ex:62` (`next_sequence/1`), `:75` `send_event/3`, `:451` `bump_sequence/2` | `internal/dialect/azure/eh_rest.go:88-127` `EhSASHeader`/`EhVerifySAS`; `:128-142` `EhPartitionKey`; `:171-202` `EhEventCount`/`EhPKPartition`/`EhStoragePartition`; `:276-349` `EhHandler.ServeHTTP` | PASS |
| 5 | C7_EVENT_PLANES.md:24 (C7-3a DCR ingest 204 + x-ms-request-id) | `lib/smalt/data_plane/sentinel.ex` `ingest/4` + `lib/smalt/egress_router.ex:1841-1844` | `internal/dialect/azure/sentinel_purview.go:99-104` `SentinelIngestPath`; `:732-767` `SentinelRowAugment` | PASS |
| 6 | C7_EVENT_PLANES.md:25 (C7-3b KQL PrimaryResult) | `sentinel.ex` `column_type/2`, `project_columns/1`, `stringify/1` | `internal/dialect/azure/sentinel_purview.go:327` `NewSentinelQueryEnvelope`; `:781` `SentinelColumnarTypeFor` | PASS |
| 7 | C7_EVENT_PLANES.md:28 (C7-5a entity POST envelope) | `lib/smalt/data_plane/purview_atlas.ex:22-36` (envelope, bare-map leniency) | `internal/dialect/azure/sentinel_purview.go:386-390` `AtlasEntityGUIDPath`; `:438-455` `AtlasBadRequest` | PASS |
| 8 | C7_EVENT_PLANES.md:29 (C7-5b bulk limit 100) | `purview_atlas.ex:53-79` (`@max_bulk 100`) | `internal/dialect/azure/sentinel_purview.go:456-461` `AtlasBulkLimitMessage` | PASS |
| 9 | C7_EVENT_PLANES.md:30 (C7-5c lineage relations) | `purview_atlas.ex` lineage (stored-edge guid) | `internal/dialect/azure/sentinel_purview.go:391-397` `AtlasLineagePath` | PASS |
| 10 | C7_EVENT_PLANES.md auth faces (publish/ingress bearer gate) | `lib/smalt/egress_router.ex` bearer gate | `internal/dialect/azure/webpubsub_token.go:49-72` `MintWebPubSubToken`; `:73-129` `VerifyWebPubSubToken`; `internal/dialect/azure/sb_rest.go:173-210` `IsSbAuthFace` | PASS |
| 11 | C7_EVENT_PLANES.md:69 GAP cross-link (`handle_cg_list/4`) | `arm_gateway/router.ex:1199` (plan table named `egress_router.ex:1199`) | `internal/dialect/azure/sb_rest.go:133-155` `ClassifySbRoute` | PASS (plan's smalt half corrected in receipt; doc not edited) |
| 12 | Provenance re-point: `eg_topic_events` | smalt caller `lib/smalt/egress_router.ex:1824` — `Kernel.++(Smalt.ArmGateway.Router.eg_topic_events(topic))` (verified on disk this session) | arcus owner `internal/dialect/azure/event_grid.go:47-48` (`EventGridEvent` struct), `:160-169` (`EventGridSchema` case of `BuildEnvelope`) | PASS |

## Counterpart file hashes (sha256 at pin time, 2026-11-05)

- `event_grid.go` 68bd0c0c7ae220550a93ecf3b5c82b572b8d93da0ae954dc8873b8f31d74143a
- `webpubsub_faces.go` 9f2c7d1adde8886e1456bdbe86d4c1510b5f650c6ee1af6f8209d6d86655ce3e
- `webpubsub_token.go` 19d530800efd7ae1098184ad94191b466de59cc28cc1c6264734457846c7c78f
- `eh_rest.go` b87a4448f5077b35f6ea90d82805ce1feccbe909f8ea221f56fa3e8201dcb581
- `sb_rest.go` 55024ce1258ccccffed66b827f382179f07e03f701ffe436be7dc7419da29fab
- `sentinel_purview.go` f534ba763066cc2e60a8d07ced2c263a2bb83b76eea0855e2e6d20205b698053

## Notes / drift observed (pre-existing, not session-introduced)

- The C7 doc pins `event_hubs.ex:62` for `next_sequence/1`, but the live tree
  has it at `event_hubs.ex:81` (smalt half kept byte-identical per plan law;
  drift recorded here only). Same class: doc rows name
  `purview_atlas.ex:22-36`/`:53-79` while `create_entity` now sits at `:175+`.
- Plan locus row "69" named `egress_router.ex:1199`; the doc's line 69 actually
  carries `arm_gateway/router.ex:1199` (`handle_cg_list/4`). Anchored against
  the on-disk truth; `ClassifySbRoute` (sb_rest.go:133-155) is the arcus
  route-classification counterpart.
- Plan's C7-2a counterpart "event_grid.go (verify at receipt)" resolved to
  `eh_rest.go` (EH REST face) — event_grid.go has no EH sequence surface; the
  dispatch contract's file list is honored.

## Commands / evidence

```sh
# func-decl line pins (grep over landed arcus tree, 2026-11-05)
grep -n '^func ' /Users/sac/arcus/internal/dialect/azure/{event_grid,eh_rest,sb_rest,webpubsub_faces,webpubsub_token,sentinel_purview}.go
# hashes above via shasum -a 256 on the same six files
# smalt caller verified:
sed -n '1810,1840p' /Users/sac/smalt/lib/smalt/egress_router.ex   # :1824 eg_topic_events merge
```

Zero silently-missing cells: all 12 rows PASS; no UNSUPPORTED/BLOCKED in this
lane's scope. No git actions.
