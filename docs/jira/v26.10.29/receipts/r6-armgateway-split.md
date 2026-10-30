# r6 — ArmGateway split (T06)

- lane: L06 · window: v26.10.29 · date: 2026-10-30 · class: decomposition
- ticket: docs/jira/v26.10.29/tickets/T06-armgateway-router-split.md
- subject: lib/smalt/arm_gateway/router.ex @ 338caed (8428 lines) split into
  focused modules behind a front plug; extraction mechanical and
  call-closure–driven (analysis data: /tmp/ggen-split/analysis.json).

## Extractions (8 modules, verbatim chunks, zero test edits)

| module | path | lines | content |
|---|---|---|---|
| Router (front) | lib/smalt/arm_gateway/router.ex | 8428 → 325 | pipeline (CORS, X-ARR cert, Bearer, Parsers, request-id echo, throttle), crash fence (handle_errors + FEGS1 fallback), typed-404 fallback `match _`, defdelegates |
| Plug.OidcSts | lib/smalt/arm_gateway/plug/oidc_sts.ex | 350 | STS token issuance (2 token routes) + OIDC discovery face (4 discovery routes) + token engine privates (handle_token, issue_token, mint_authority, openid_envelope, …) |
| Plug.Metadata | lib/smalt/arm_gateway/plug/metadata.ex | 153 | IMDS face (GET /metadata/identity/oauth2/token), /metadata/endpoints, /.well-known/health/{live,ready} |
| Plug.SubscriptionRouter | lib/smalt/arm_gateway/plug/subscription_router.ex | 998 | tenant(s), subscriptions, LRO operations polling, RG CRUD + LRO delete, locations, eventtypes, skus/usages, tagNames/tagValues, exportTemplate/moveResources |
| Plug.ResourceProviders | lib/smalt/arm_gateway/plug/resource_providers.ex | 5828 | providers, locks, cost management, children (subnets/keys/containers/queues/topics/eventhubs/DocumentDB/privateDnsZones), metrics, deployments, EventGrid, policy*, roleAssignments, DCRs, workspaces, generic provider face, azapi actions, dnsZones, RG-scope tags, $Resources/entity faces, glob routes |
| Plug.Common | lib/smalt/arm_gateway/plug/common.ex | 869 | shared wire/gate helpers (send_json, send_list, send_arm_error, send_graphlaw_refusal, send_engine_unavailable, check_api_version/check_version/version_lte?/version_base/strict_version_validation?, find_admitted, request_authority, affidavit seal sideband incl. public affidavit_witness, pagination, tags envelopes) |
| Engine.Policy | lib/smalt/arm_gateway/engine/policy.ex | 239 | admission-gate engine (check_admission_gate, admission envelope, check_shape family, resource_id/ns_of/leaf_of) — public, imported by ResourceProviders |
| Engine.Lro | lib/smalt/arm_gateway/engine/lro.ex | 118 | async_put_response, lro_type?, lro_async_update_type?, lro_wire_body — public, imported by SubscriptionRouter + ResourceProviders |

The ggen scaffolds at /tmp/ggen-split/tree/ are placeholders; the landing is
mechanical verbatim extraction (transitive call-closure partition; handlers
exclusive to one family moved with it, shared handlers to Common).

## Wire-parity evidence (mechanical, pre-court)

- routes 1:1 — 285 routes: 0 missing, 0 extra (case-variant paths preserved).
- defs 1:1 — 216 defs: 0 missing; EXTRA ×1 each for `rg_from_resource_id` and
  `storage_account_names` = local shadow copies left in ResourceProviders with
  byte-identical bodies (local defs shadow the identical imported bodies —
  duplication, not drift).
- attrs 0 missing / 0 extra (multi-user attrs re-emitted per owner module;
  @fegs1_* stay on Router; @rg_type/@system_data live only where used).
- public API preserved via defdelegate on the front module:
  affidavit_witness→Common; lock_policy_etag, eg1_publish, eg_topic_events,
  eg_topic_input_schema→ResourceProviders; rate_table_for_test stays real.
- cascade: front Router keeps auth/rate-limit + request-id echo + the
  api-version gate (per-route check_api_version via Common), then
  OidcSts → Metadata → SubscriptionRouter → ResourceProviders at the
  canonical seam (after FunctionsRouter/CanonicalRouter, before :match). Each
  family plug ends in a pass-through `match _` tail — a conn no route claimed
  returns UNCHANGED (not halted), so the front Router's typed-404 fallback
  answers exactly as before. Order preserves first-match-wins precedence
  (families shape-disjoint; within-family order verbatim).
- crash fence intact: front Router's Plug.ErrorHandler wraps the whole
  pipeline, so family-route crashes reach handle_errors unchanged.

## Compile receipts

- `MIX_BUILD_ROOT=_build-l06 mix compile` — 0 errors at 23:51 and re-verified
  23:58/00:00 after foreign-lane churn settled (153→fewer warnings, none
  error-class; warnings are pre-existing repo-wide + unused-alias noise).

## Foreign-lane disclosure

Zero edits to foreign files by this lane. Three foreign compile freezes were
waited out by bounded polls on the shared compile (data_plane/blob_storage.ex
23:10–23:22, data_plane/blob/leases.ex 23:28–23:51, appconfig_kv_refs.ex
23:53–00:00 — all landed by their owner; no unblock fix applied by L06).

## Gate — WITNESSED (coordinator rerun, 2026-10-30 02:15)

`MIX_BUILD_ROOT=_build-l06 mix test test/internal test/integration` →
`1239/1302 passed, 7 skipped, 12 excluded, 63 failed` (483.7s). Versus the
r0 pre-implementation baseline (143 failed / 1417): the undock restore +
split wave cut the failure count by 80; the residual 63 are the
r4-triage-documented egress/fence/tenant classes, owned by the
next-wave lanes (L07 split cycle 3 + fence restoration in flight).
Standing: **ALIVE for the split subject; gate honestly PARTIAL on
pre-existing residue** (zero test edits; failure classes cited, not
masked).