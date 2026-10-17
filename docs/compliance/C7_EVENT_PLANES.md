# C7 Event Planes Compliance

Status vocabulary: **CONFORMANT** = matches the external contract as pinned here;
**PARTIAL** = implemented with a named divergence from the real service; **GAP** =
not implemented. Every row names the smalt file:line and the fence test in
`test/compliance/c7_events.exs`. All rows probed live (real HTTP over
`Smalt.EgressRouter` on an ephemeral Bandit port; real ETS through
`Smalt.Messaging.EventHubs`, `Smalt.DataPlane.Sentinel`,
`Smalt.DataPlane.ResourceGraph`, `Smalt.DataPlane.Purview`) 2026-10-14:
`mix test test/compliance/c7_events.exs` -> **17 tests, 0 failures**.

## Surface map

| id | Surface | Status | smalt pin (file:line) | Divergence vs real service | Fence (test name fragment) |
|---|---|---|---|---|---|
| C7-1a | CloudEvents 1.0 structured mode: `application/cloudevents+json`, single JSON object admitted as one event | CONFORMANT | `lib/smalt/egress_router.ex` (route, JSON content-type gate, object -> one structured event, `valid_cloudevent?/1`, 200-empty response) | None: smalt answers **200 with an EMPTY body**, the real Event Grid publish shape. The legacy `{"status":"Published",...}` envelope survives only behind `:smalt, :eventgrid_response_mode == "per-event"` (compat mode; single event -> old envelope, batch -> `[{"id","status"}]` array). | "structured mode" |
| C7-1b | Batch mode: `application/cloudevents-batch+json`, JSON array admitted as a batch | CONFORMANT (admission + response) | `_json` array -> batch; `respond_published/3` (200-empty default, per-event array behind `eventgrid_response_mode`) | None in default mode: batches are acknowledged with an empty 200, matching real Event Grid. Per-event batch status reporting exists only behind the `per-event` compat mode; default admission remains strictly all-or-nothing (row C7-1d). | "batch mode" |
| C7-1c | Binary mode: `ce-*` headers carry context attributes, body is `data` | CONFORMANT | `binary_mode_headers?/1` (`ce-specversion` + ce-source or ce-type), `binary_mode_event/2` (body -> `data`, HTTP content-type -> `datacontenttype`) | None material: `ce-specversion`/`ce-id`/`ce-source`/`ce-type` on headers, `datacontenttype` from content-type — exactly the spec's binary-mode roles. | "binary mode" |
| C7-1d | REQUIRED-attribute gate + all-or-nothing batch admission | CONFORMANT (gate) / PARTIAL (admission model) | `lib/smalt/messaging/event_stream.ex:32-47` + `:114` (`event_id/1` UUID stamp), router (validate before any store write), `validate_events/1`, error shape | Two named divergences: (1) spec makes `id` REQUIRED; smalt stamps a UUIDv4 when absent instead of refusing (`event_stream.ex:114-119`) — lenient beyond spec; (2) CNCF binding mandates neither all-or-nothing nor a per-event format; real Event Grid reports per-row status (reachable only via the `per-event` compat mode). smalt: one invalid event -> `400 {"error":{"code":"InvalidCloudEvent"}}`, nothing stored. | "REQUIRED attributes" (both tests) |
| C7-1e | Non-JSON content-type -> 415 `UnsupportedMediaType` | CONFORMANT (as-designed) | JSON content-type gate, 415 error shape | Deliberate smalt tightening: neither the CNCF binding nor Event Grid mandates 415 on non-JSON. Pinned as designed behavior, not claimed as spec parity. | "non-JSON content-type" |
| C7-2a | Event Hubs: strictly monotonic per-partition sequence from 1 | CONFORMANT (module tier) | `lib/smalt/messaging/event_hubs.ex:63` (`next_sequence/1`), `:207` (`bump_sequence/2`), `:74` (`send_event/3`) | Real EH assigns sequences per partition 0..N-1; smalt accepts any partition key (see C7-2c). | "[eh] strictly monotonic" |
| C7-2b | Event Hubs: sequence-ordered receive + reconcile + CAS checkpoint | CONFORMANT (module tier) | `:89` (`receive_events/3`), `:157` (`reconcile/2`), `:118` (`compare_and_swap/4`) | `$default` consumer group exists only as a checkpoint-key convention (`{group, partition}`), no group enumeration surface. | "[eh] send/receive" |
| C7-2c | Event Hubs partition naming / metadata surface | PARTIAL | `event_hubs.ex:63` — any partition string accepted | Real EH: partitions 0..N-1 pre-provisioned; `getEventHubProperties` returns `name`, `createdTime`, `partitionIds`. smalt has **no partition-count/metadata surface at any tier**; `$default` is a key convention only. | "partitions are free-form names" |
| C7-3a | Log Analytics DCR ingest: `POST /dataCollectionRules/:dcr/streams/:stream?api-version=2023-01-01` | CONFORMANT | `lib/smalt/data_plane/sentinel.ex` (`ingest/4` -> `{:ok, 204, ""}`), api-version gate, route `lib/smalt/egress_router.ex` (204 + `x-ms-request-id` header, v4 dashed GUID form unified with the ARM surface 2026-10-15; fence pins byte-exact GUID shape) | None: smalt answers **204 No Content with `x-ms-request-id`**, the real Logs Ingestion API shape. api-version gate (2023-01-01) is real. | "[la] DCR ingest" (module + wire tests) |
| C7-3b | KQL query PrimaryResult envelope | CONFORMANT (order + scalar types) | `sentinel.ex` envelope, `project_columns/1` (project order preserved), `column_type/2` (integer -> `"long"`, float -> `"real"`, boolean -> `"bool"`, else `"string"`), `stringify/1` | Values are still stringified in `rows` and datetime/dynamic inference is absent: a datetime string reports `"string"` (real KQL reports `"datetime"`), and object/array values report `"string"` rather than `"dynamic"`. | "[la] query PrimaryResult envelope" |
| C7-4a | Resource Graph response contract: `count`/`data`/`totalRecords`/`resultTruncated`/`$skipToken` | CONFORMANT | `lib/smalt/data_plane/resource_graph.ex` (`query/3`, response assembly, `resultTruncated` = filtered set exceeds the hard server cap of 1000) | None: `resultTruncated: true` now means "results may be incomplete due to server limits" (hit on the cap); normal `$skipToken` pagination keeps `false`, matching real Resource Graph semantics. | "[rg] response contract" |
| C7-4b | Resource Graph request-form continuation | CONFORMANT | `resource_graph.ex` `skip_token/2` — primary read is `options.$skipToken`, flat top-level `"skiptoken"`/`"$skipToken"` kept only as fallback | None: the real API's `{"options":{"$skipToken": ...}}` request form is the primary read; the flat form survives only as a compat fallback. | "[rg] response contract" (page2/page3 legs) |
| C7-5a | Purview entity POST: `{referredEntities, entity}` envelope + bare-map leniency | PARTIAL | `lib/smalt/data_plane/purview_atlas.ex:22-30` (`:24` envelope, `:26` bare map), route | Real Atlas `POST /atlas/v2/entity` takes `AtlasEntityWithExtInfo` (`{referredEntities, entity}`) and returns the entity with `MutationInfo`; smalt returns the bare stored entity, no MutationInfo. | "entity POST accepts" |
| C7-5b | Purview bulk: limit 100, atomic over-limit refusal, `guidAssignments`+`mutatedEntities` | CONFORMANT (limit + atomicity) / PARTIAL (response shape) | `purview_atlas.ex:44-73` (`@max_bulk 100` at `:14`), route | Real Atlas bulk response carries `MutationInfo` per entity inside `mutatedEntities`; smalt's `mutatedEntities.CREATE` holds the bare entities. Over-limit -> 400 `ATLAS-400-00-001`, no partial insert (fenced). Fence (2026-10-15) additionally pins the full 100-entry identity `guidAssignments` map and exact `mutatedEntities.CREATE` length/guid-set. | "bulk <= 100" |
| C7-5c | Purview lineage BFS: `baseEntityGuid`/`guidEntityMap`/`relations` | CONFORMANT | `purview_atlas.ex` lineage — `relationshipId` taken from the **stored edge guid** (`edge["relationshipId"]`, `"from->to"` only as fallback when the edge was stored bare) | None: lineage relations carry the stored relationship identity, as real Atlas v2 does. | "lineage" |

## Named divergences (summary)

1. `id` auto-stamp lenient beyond spec (`event_stream.ex:114`).
2. Event Hubs partition metadata absent at all tiers (`event_hubs.ex:63`);
   `$default` a key convention only.
3. KQL: values stringified in `rows`; datetime/dynamic column-type inference
   absent (`sentinel.ex` `column_type/2`).
4. Atlas: no `MutationInfo` in entity/bulk responses.
5. Compat escapes kept behind config: `eventgrid_response_mode = "per-event"`
   (legacy publish envelope / per-event status array), flat `skiptoken`
   request form, bare-edge `"from->to"` relationshipId fallback.

## GAP list (not implemented)

Convention note (V261014-13): the `GAP(name)` tokens below are **typed
UNSUPPORTED** — deliberately not implemented this release, not open defects.
Each carries a close condition; closing one requires landing the surface and
deleting the token from this file and `docs/WIRE_PARITY.md`.

- `GAP(eventgrid-eg1-schema-absent)` — UNSUPPORTED: Event Grid **native event
  schema** (EG1/`GRIDEVENT`, system-topic events) not implemented; smalt
  admits CloudEvents 1.0 only. **Narrowed 2026-10-16 (see
  cap-eventgrid-topics receipt, docs/jira/v26.10.16/receipts/): EG1 ingest
  now admitted for ARM topics explicitly declared
  `inputSchema: "EventGrid"`; token stays OPEN for un-declared topics and
  system-topic-sourced event ingest.** Close condition: EG1 schema admission path on
  `POST /topics/:topic/events` with a wire fence distinguishing EG1 from
  CloudEvents payloads.
- `GAP(eventhubs-partition-metadata-absent)` — ~~UNSUPPORTED~~ RETIRED
  (2026-10-15/16): surface served per `docs/jira/v26.10.14/receipts/s2-eh-shims.md`
  (KD-19 closed; properties/partition surface returning `name`,
  `createdTime`, `partitionIds`; see WIRE_PARITY.md:148 for the struck
  token). Row C7-2c and the cross-links below refer to this retired token.
- `GAP(eventhubs-consumer-group-enumeration-absent)` — ~~UNSUPPORTED~~ RETIRED
  (2026-10-16): hub-scoped consumer-group LIST served per
  `docs/jira/v26.10.16/receipts/cap-eh-consumergroups.md` — synthesized `$default`
  via the `build_resource_record` envelope (exactly-once even when a client PUTs a
  literal `$default`), `handle_cg_list/4` (`arm_gateway/router.ex:1117`), evidence
  15/0 `sb_children_test.exs` + 18/0 cascade family (sb_children 15 +
  arm_cascade_teardown 3). Cross-links below refer to this retired token.
- `GAP(atlas-search-relationship-get-absent)` — UNSUPPORTED: Atlas entity/
  audit search (`POST /atlas/v2/search/collection`) and relationship read/GET
  beyond the edge-minting POST: not implemented. Close condition: search/collection
  POST plus relationship GET over stored `:smalt_purview_edges` guids.
- `GAP(kql-datetime-dynamic-types-absent)` — UNSUPPORTED: KQL datetime/dynamic
  column-type inference not implemented (values report `"string"`). Close
  condition: `column_type/2` infers `"datetime"` for datetime strings and
  `"dynamic"` for object/array values (row C7-3b).

Service Bus (AMQP plane, V261014-08 typed UNSUPPORTED): session reply-to
(`reply_to` / `reply_to_session_id`) — stored nowhere, emitted nowhere;
SDKs observe the field **dropped, not rejected**. Subscription rules
(add-rule / remove-rule / SQL filter / correlation filter / default rule
`$Default`) — no subscription concept, no filter evaluator; add-rule stays
`:unknown-op` (fail-closed 501). Tokenized in WIRE_PARITY + C5 R11.

Cross-links: row C7-2c ↔ `GAP(eventhubs-partition-metadata-absent)`;
§Named divergences item 2 ↔ `GAP(eventhubs-partition-metadata-absent)` +
`GAP(eventhubs-consumer-group-enumeration-absent)`; item 3 ↔
`GAP(kql-datetime-dynamic-types-absent)`.

## Replay

```sh
mix test test/compliance/c7_events.exs   # 17 tests, 0 failures (2026-10-15 lens-8 re-measured)
mix test test/compliance/c7_events.exs test/eventgrid_conformance_test.exs \
  test/data_plane/audit_planes_test.exs test/ocel_revops_test.exs  # 64 tests, 0 failures
```

Fences fail (fail-closed) if any pinned shape moves: response envelopes (200-empty
publish, 204+`x-ms-request-id` ingest), all-or-nothing admission, api-version
gates, the bulk-100 limit, projected column order, value-shaped KQL column types,
`resultTruncated` cap semantics, the `options.$skipToken` request form, and the
stored-relationship-guid lineage identity. Any of those changing requires a
conscious row update here, not a silent drift.
