# AUD-3: ARM + management plane — SDK source vs smalt gateway

Lane AUD-3, 2026-10-15. Adversarial code-level audit. SDK ground truth extracted
from the vendored dists actually shipped in this tree; smalt side read from
`lib/smalt/arm_gateway/router.ex` (1866 lines), `lro.ex`, `registry.ex`. Every
claim cites SDK file:line + smalt file:line. READ-ONLY lane; this file is the
only write.

## Sources of record

- TS: `test/sdk-full/node_modules/@azure/arm-resources` 8.0.0 (dist/esm)
- TS LRO: `@azure/core-lro` dist/esm/http/operation.js
- TS auth: `@azure/msal-node` lib/msal-node.cjs
- PY: `azure-mgmt-resource` 23.4.0 at
  `smalt-cli/.venv-cli/lib/python3.13/site-packages/azure/mgmt/resource/resources/operations/_operations.py`
- PY LRO: `azure/mgmt/core/polling/arm_polling.py`
- smalt: `lib/smalt/arm_gateway/router.ex` (R), `lib/smalt/arm_gateway/lro.ex` (L),
  `lib/smalt/smalt/registry.ex` → actually `lib/smalt/registry.ex` (REG)

## A. Route inventory — every SDK operation signature vs smalt routes

### arm-resources (TS 8.0.0) + azure-mgmt-resource (PY 23.4.0) signatures

| # | SDK signature (method + path template) | SDK cite | smalt route | smalt cite | class/KD |
|---|---|---|---|---|---|
| 1 | GET /subscriptions/{sub}/resourcegroups | py `_operations.py:205`, ts `resourceGroups/operations.js:45` | `get "/subscriptions/:sub_id/resourcegroups"` + camelCase twin | R:1270-1276 | FULL (wired) |
| 2 | PUT /subscriptions/{sub}/resourcegroups/{rg} | py:76-179, ts:74 | `put .../resourcegroups/:rg_name` (+camel twin) | R:1279-1285, handler R:508-534 | FULL — 201/200 by existed?, api-version gated (R:497-533) |
| 3 | SDKs' expected RG PUT statuses 200/201 (py `_delete_initial`-style deserializers; ts `expectedStatuses ["200","201"]` class) | ts `restorePollerHelpers.js:48-50` (200/202/204 delete; 200/202/201 put) | matches 200/201 | R:533 | FULL |
| 4 | DELETE /subscriptions/{sub}/resourcegroups/{rg} | py:76-125, ts:74 | delete + LRO 202 Location+Retry-After | R:1295-1301, handler R:578-609 | FULL (TS/PY pollers verified compatible, §C) |
| 5 | PATCH /subscriptions/{sub}/resourcegroups/{rg} | ts probe witnessed `resourceGroups.update` PATCH | NO ROUTE — catch-all `match _` 404 RouteNotFound | R:1857-1865; witness `sdk-results/ts-arm-resources.md` D3 | **MISSING-UNREGISTERED (KD-32)** |
| 6 | GET .../resourcegroups/{rg}/resources | py:271, ts:434 | NO ROUTE | witness ts-arm-resources D2 | **MISSING-UNREGISTERED (KD-31)** |
| 7 | GET /subscriptions/{sub}/locations | ts probe (SubscriptionClient raw fetch) | NO ROUTE | witness ts-arm-resources D1 | **MISSING-UNREGISTERED (KD-30)** |
| 8 | GET /subscriptions/{sub}/resources (list across sub) | py:660, ts `resources/operations.js:9` | NO ROUTE — C-5 P1 storm hit these 404s | witness `receipts/c5-arm-storm.md` P1 | **MISSING-UNREGISTERED (new, propose KD-54)** |
| 9 | GET /subscriptions/{sub}/providers | py:1032, ts `providers/operations.js:67` | present, but aggregate-only: one Provider envelope, namespace "Microsoft.Resources" for ALL types, empty locations, single apiVersions entry | R:1307-1343 | PARTIAL-STUB — shape diverges from Provider list semantics (one Provider per namespace) |
| 10 | GET /subscriptions/{s}/providers/{ns} | py:1060, ts `providers/operations.js:37` | NO ROUTE | catch-all R:1857 | **MISSING (new, KD-55)** |
| 11 | GET /providers and GET /providers/{ns} (tenant-level provider list/get) | ts `providers/operations.js:212` / :8; py:1089 | NO ROUTE | R:1857 | **MISSING (KD-55 family)** |
| 12 | POST .../providers/{ns}/register, /unregister | ts `providers/operations.js:95,183`; py:1005,929 | NO subscription-level POST route (only azapi POST under resourcegroups, R:1788-1794) | R:1788 | **MISSING (new, KD-56)** |
| 13 | GET /providers/Microsoft.Resources/operations | py:57, ts `operations/operations.js:8` | NO ROUTE | R:1857 | **MISSING (minor, KD-56 family)** | 
| 14 | PUT/GET .../providers/{ns}/{type}/{name} (generic resource) | py:475-627, ts:39-184 | generic PUT/GET/DELETE routes + admitted-type + shape gates | R:1799-1838 | FULL (wired; LRO types 202/200 + async headers R:632-648, R:1094-1102) |
| 15 | /{resourceId} PUT/PATCH/GET/DELETE (by-id) | py:354-448, ts:214-339 | served via the same generic routes when the id is the 5-segment form; TS probe 5/6/9 PASS | ts-arm-resources probes 5,6,9 | FULL for the 5-segment form; **KD-24 double-slash still 404s the `parentResourcePath=""` form** (py-arm-resources D3) |
| 16 | PATCH /{resourceId} (updateById, expected 200/202/201) | ts:243-260 | generic PUT route is PUT-only; PATCH falls to nested-glob PUT handler (R:1844) which only serves diagnosticSettings → 404 RouteNotFound for all other PATCHes | R:1844-1854 vs R:1799 | **MISSING (new, KD-57: PATCH on generic resources)** |
| 17 | tag CRUD: /subscriptions/{sub}/tagNames... | py:785-880, ts `tagsOperations/operations.js:9-121` | NO ROUTE | R:1857 | **MISSING (new, KD-58)** |
| 18 | PUT/GET/DELETE/PATCH /{scope}/providers/Microsoft.Resources/tags/default | py:690-767, ts:148-248 | resource-scope PUT matches generic route R:1799 → `find_admitted("Microsoft.Resources/tags")` nil → GraphLaw 400 InvalidResourceShape | R:1041-1053 | **UNSUPPORTED-REGISTERED** (routed but refused, typed 400 — not silent 404; new KD-58 family) |
| 19 | RG exportTemplate / moveResources / validateMoveResources | py:236-330; ts:364-399 | NO ROUTE | R:1857 | **MISSING (new, KD-59)** |
| # | deployment operations (deployments/{name}/operations) | NOT EXPOSED by either vendored SDK build: TS dist has no `deployments` op dir (api/ listing: operations, providerResourceTypes, providers, resourceGroups, resources, tagsOperations); PY combined `_operations.py` has zero `/deployments` _url rows (grep, 0 hits :57-1117) | n/a | — | N/A — not exercised by these SDK builds; do not claim as a smalt gap from this lane |
| 20 | GET /tenants | ts-arm-resources secondary note: arm-subscriptions 6.0.0 modular client no longer exposes tenants.list; PY vendored set has no tenant op | smalt SERVES it: `get "/tenants"` + `/tenant` | R:1202-1208 | smalt-side FULL; no vendored SDK operation reaches it (server-side surplus, not a gap) |
| 21 | GET /subscriptions + /subscriptions/{sub} | py probe P1; ts probe 2 PASS | present, api-version presence-only gate | R:1218-1244 | FULL |
| 22 | STS POST /{tenant}/oauth2/v2.0/token (client_credentials) | msal-node posts client_credentials; validated grant/creds | R:1114-1120, validation R:183-225 | FULL (wired both SDK tiers) |
| 23 | msal instance discovery `{authority}/common/discovery/instance` | msal-node.cjs:225 | route present | R:1170-1185 | FULL route; the witnessed ClientSecretCredential `endpoints_resolution_error` (ts-arm-resources bootstrap §1, msal-node.cjs:532) needs a re-run to adjudicate whether discovery routes landed after the witness — routes exist on disk today |
| 24 | msal tenant discovery `{authority}/{tenant}/v2.0/.well-known/openid-configuration` | msal-node.cjs:2394 | route present | R:1191-1193 | FULL route (same re-run caveat as #23) |
| 25 | api-version handling: TS v8 defaults 2025-04-01 | ts-arm-resources "api-version ceiling" note | Registry latest pins RG 2021-04-01 → hard 400 | R:1019-1039; REG:135 | PARTIAL — documented emulator contract; every newer-profile client 400s at the gate |

### Signature counts

- FULL (wired + witnessed or code-verified compatible): 14 signatures
- PARTIAL-STUB: 3 (#9 providers aggregate, #25 api-version ceiling, LRO 201-vs-202 below)
- MISSING-UNREGISTERED: 10 signatures (KD-30/31/32 + new KD-54..59 families)
- UNSUPPORTED-REGISTERED: 1 (tags at resource scope, typed GraphLaw 400)
- N/A (not exercised by these SDK builds): deployment operations

## B. LRO wire semantics (deep-dive)

- smalt LRO PUT: 202 (create) / 200 (update) + `azure-asyncoperation` + `location`
  + `retry-after: 1`, body = op record with `"status"` member — R:632-648,
  R:1094-1102, L:31-57.
- TS `inferLroMode` reads `operation-location` first, falls back to
  `azure-asyncoperation`; OperationLocation mode reads status from `body.status`
  — core-lro `http/operation.js:24-29, 55-83, 136-159`. smalt's envelope
  satisfies this. TS accepts initial 200/201/202 (restorePollerHelpers.js:48-50);
  smalt never answers 201 on LRO PUT — legal (subset), noted not a divergence.
- PY `ARMPolling` chains AzureAsyncOperationPolling → LocationPolling →
  BodyContentPolling (arm_polling.py:73-77, 188-200); 202→InProgress,
  201→provisioningState read, 200→provisioningState, else OperationFailed —
  arm_polling.py:141-155. smalt 202+status-body satisfies it. PY P3 witnessed
  PASS (py-arm-resources.md P3).
- RG delete: 202 + `location` + `retry-after` (R:586-609) — TS DELETE with
  resourceLocationConfig "location" → ResourceLocation mode, polls Location,
  terminal by status code (core-lro operation.js:34-38, 47-49, 77-82); PY
  LocationPolling — compatible. Witnessed: ts probe 10, py P3c.
- Divergence (OPEN KD-26 / py D5): LRO terminal resource GET reportedly lacks
  `properties.provisioningState` (SDK state=None) — py-arm-resources D5 — yet
  `handle_resource_put` writes `provisioningState` into the record at PUT time
  (R:623-624). The KD-26 close condition should re-witness; the code as written
  should carry it. Registered, not adjudicated from this lane.
- Sweeper: terminal flip also at rest (L:14-19, lro_sweeper.ex) — no SDK
  counterpart needed; wire-neutral.

## C. Auth / STS vs msal

- msal instance discovery: `{canonicalAuthority}discovery/instance?api-version=1.1&authorization_endpoint=`
  (msal-node.cjs:225) — smalt serves GET /common/discovery/instance (R:1170).
  Note msal builds it as `common/discovery/instance` under the authority root —
  smalt route is `/common/discovery/instance`, exact match. Good.
- Tenant OIDC: `{authority}/{tenant}/v2.0/.well-known/openid-configuration`
  (msal-node.cjs:2394) — smalt R:1191. Exact match.
- Token endpoint validation: dup-param refusal via raw-body cache (R:190-209),
  grant_type/client_id/secret gates (R:211-222), no-store/no-cache (R:171-177,
  265-266) — OAuth 5.1/5.2 conformant.
- Open: ClientSecretCredential `endpoints_resolution_error` (msal-node.cjs:532)
  witnessed in ts-arm-resources bootstrap §1 against the then-live substrate;
  the discovery routes exist on disk today (R:1170-1193). Falsifier: re-run
  ClientSecretCredential with `authorityHost` = live authority. Not adjudicated
  here.
- KD-35 (http-only egress vs azure-core refusing Bearer over http,
  py-arm-resources D2) — registered, stands.

## D. Rate-limit class (C-5 P4)

C-5 P4 witnessed 100/100 201s, zero 429 (receipt c5-arm-storm.md P4). The tree
NOW carries `arm_throttle` (R:100-157): configurable `:smalt, :arm_rate_limit`,
429 TooManyRequests + Retry-After, fixed 1s window, default :infinity. So the
divergence is now a default-off configuration divergence, not structural absence
— but the C-5 verdict stands as the default-behavior divergence: out-of-the-box,
retry-on-429 client paths remain untestable.

## E. Registry surface vs SDK type surface

Registry admits 39 types (REG:17-56). Both SDK tiers' wire surface that reaches
smalt exercises: RGs, generic resources, by-id ops, providers, tags-at-scope.
Types the SDKs reference that Registry does NOT admit (→ GraphLaw 400
InvalidResourceShape on PUT, R:1041-1053):
- `Microsoft.Resources/tags` (#18)
- `Microsoft.Authorization/locks` (only as an azapi action envelope, R:969-979;
  not a PUT-admitted type)
- `Microsoft.Subscription/*` (arm-subscriptions 6. Microsoft.Subscription/cancel, rename, enable, acceptOwnership — arm-subscriptions dist/esm/operations/subscription.js:111-188) — no routes, would 404 anyway
- `Microsoft.Subscription/aliases` (arm-subscriptions dist/esm/operations/alias.js:109-167) — no routes
- `Microsoft.Subscription/policies` (subscriptionPolicy.js:96-146) — no routes
- `Microsoft.Subscription/operations` (operations.js:81) — no routes
- arm-subscriptions 6.0.0 modular client has NO tenants/locations operations (grep over dist/esm: 0 hits; secondary note in ts-arm-resources.md) — so the missing smalt locations route (KD-30) is exercised by raw fetch / SubscriptionClient-class clients, not by this vendored arm-subscriptions build

## F. GAP blocks (new, for the KD register)

### GAP-AUD3-54 (propose KD-54): subscription-level resource list
GET /subscriptions/{sub}/resources — TS `resources/operations.resources.list()`
default op; py `_operations.py:660`. No smalt route (catch-all 404 R:1857).
Witnessed live: c5-arm-storm.md P1 (1600 of 2000 storm reads 404'd this path).
Falsifier: `client.resources.list()` → 200 value[].
Close: add route (prefix scan over :smalt_resources, type filter like R:1808-1827).

### GAP-AUD3-55 (propose KD-55): provider surface holes
GET /subscriptions/{sub}/providers/{ns} (py:1060; ts providers/operations.js:37),
tenant GET /providers and /providers/{ns} (ts:212, :8; py:1089), GET
/providers/Microsoft.Resources/operations (py:57; ts operations/operations.js:8).
All catch-all 404 (R:1857). Falsifier: raw curls → 200 Provider envelope.
Close: per-ns Provider envelope derived from Registry.

### GAP-AUD3-56: provider register/unregister
POST /subscriptions/{sub}/providers/{ns}/register|unregister (ts:95/:183; py:1005/:929)
+ providerPermissions (ts:128; py:977). No POST route at subscription level.
Falsifier: providers.add() → 200 Provider with "registrationState": "Registered".

### GAP-AUD3-57: generic PATCH
PATCH on generic resource or /{resourceId} (ts:243-260 updateById expected
200/202/201). Falls to the diagnosticSettings-only glob handler → 404
RouteNotFound. Falsifier: updateById → 200 patched body.

### GAP-AUD3-58: tag operations
tagNames CRUD (py:785-880; ts tagsOperations/operations.js:9-121) → 404;
resource-scope tags/default (py:680-767) → GraphLaw 400. Typed choice per type:
add routes or mint UNSUPPORTED token.

### GAP-AUD3-59: RG export/move
exportTemplate / moveResources / validateMoveResources (py:236-330; ts:36-399)
→ 404. Falsifier: begin_export_template poller reaches terminal; move then get
shows the id change.

## G. Verdict

ARM control plane is FULL for the core RG + generic-resource + by-id + LRO
surface (14 signatures, SDK-court-witnessed), PARTIAL on the provider/tag plane
(stub aggregate + routed-but-refused tags), MISSING for 10 SDK operations
(KD-30/31/32 + KD-54..59), UNSUPPORTED-REGISTERED for tags-at-scope (typed
GraphLaw 400, not silent). LRO header envelope (Azure-AsyncOperation + Location
+ Retry-After, 202/200 initial, default-terminal polling) is FULL for both SDK
tiers. Auth discovery envelope routes exist on disk; the msal
endpoints_resolution_error witness needs a re-run to adjudicate. The KD-26
provisioningState divergence looks inconsistent with current code (R:623-624
writes it) — re-witness before closing.
