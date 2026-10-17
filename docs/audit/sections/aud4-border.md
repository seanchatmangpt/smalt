# AUD-4 Wire-Parity Audit — Border Surfaces (Sentinel/Log Analytics, Resource Graph, APIM, Cognitive Search, Purview/Atlas)

Lane AUD-4, adversarial mechanical code-level audit, SDK source vs smalt
implementation, read-only. Every claim cites SDK source + smalt source.

SDK sources used (exact subjects):

- PY: `test/sdk-python/.venv-rg/lib/python3.14/site-packages/azure/monitor/query/_operations/_operations.py`
  (azure-monitor-query 2.0.0), `.../azure/mgmt/resourcegraph/operations/_resource_graph_client_operations.py`
  (azure-mgmt-resourcegraph 8.0.1)
- TS (fetched to /tmp because not vendored on this machine; versions pinned):
  `@azure/monitor-ingestion@1.2.0` `dist/esm/api/operations.js`,
  `@azure/monitor-query@1.3.3` `dist/esm/generated/logquery/src/{azureLogAnalyticsContext,operations/query}.js`,
  `@azure/arm-apimanagement@10.0.0` `dist/esm/operations/*.js`,
  `@azure/search-documents@13.0.0` `dist/esm/searchIndex/api/operations.js` + `dist/esm/search/api/operations.js` + `dist/esm/searchClient.js`,
  `@azure-rest/purview-catalog@1.0.0-beta.5` `types/purview-catalog-rest.d.ts`

Note on package identities: the audit order named `@azure/apimanagement` (no
such npm package — the mgmt-plane SDK is `@azure/arm-apimanagement`) and
`@azure/purview-catalog` (retired; the REST-level package is
`@azure-rest/purview-catalog`, last published 1.0.0-beta.5). Line citations
below use the real packages.

## 1. Sentinel / Log Analytics

SDK wire shapes:

- Ingest: `@azure/monitor-ingestion@1.2.0 dist/esm/api/operations.js:7` —
  `POST /dataCollectionRules/{ruleId}/streams/{stream}?api-version`; body =
  JSON array of objects (`body.map(...)` operations.js:31); expected status
  `["204"]` (operations.js:24); optional `Content-Encoding: gzip`
  (operations.js:14). api-version enum `V20230101 = "2023-01-01"`
  (`dist/react-native/models/models.js:4`).
- Query: `@azure/monitor-query@1.3.3
  dist/esm/generated/logquery/src/azureLogAnalyticsContext.js:34,38` — base
  `https://api.loganalytics.io/v1`; `operations/query.js:107,123` —
  `POST /workspaces/{workspaceId}/query`. Effective URL:
  `https://api.loganalytics.io/v1/workspaces/{id}/query`. Python 2.0.0
  confirms: `_operations.py:53` `_url = "/workspaces/{workspaceId}/query"`.
  The python 2.0.0 package has NO ingestion operation at all (Logs Ingestion
  lives in `azure-monitor-ingestion`); only `/workspaces/{id}/query`,
  `/{resourceId}/query` (:79) and `/$batch` (:103).

smalt: route `post "/dataCollectionRules/:dcr/streams/:stream"`
(egress_router.ex:684) → `Sentinel.ingest/4` (sentinel.ex:30); route
`post "/v1/workspaces/:workspace_id/query"` (egress_router.ex:708) →
`Sentinel.query/2` (sentinel.ex:212).

| # | SDK operation (wire) | State | smalt site | gap / KD |
|---|---|---|---|---|
| 1 | Logs Ingestion upload `POST /dataCollectionRules/{ruleId}/streams/{stream}?api-version=2023-01-01` (operations.js:7) | FULL-WIRE-SUPPORT | egress_router.ex:684 → sentinel.ex:30,113-137 | template exact; 204 + `x-ms-request-id` (egress_router.ex:695); api-version gate exact (sentinel.ex:14,69-72); array-of-objects-only 400 (sentinel.ex:55-66) |
| 2 | Ingest to never-created DCR | PARTIAL-WIRE-STUB | sentinel.ex:46-53 | real service 404s; smalt lazy-creates by default (documented divergence, `:sentinel_dcr_strict` flag proves the fix shape) |
| 3 | Gzip `Content-Encoding` upload (operations.js:14) | MISSING-UNREGISTERED | not read anywhere in ingest path (egress_router.ex:684-706 never inspects content-encoding) | compressed batches stored as raw gzip bytes |
| 4 | Query `POST /v1/workspaces/{id}/query` (azureLogAnalyticsContext.js:34 + query.js:107) | FULL-WIRE-SUPPORT (template) | egress_router.ex:708 → sentinel.ex:212 | template exact vs api.loganalytics.io/v1 |
| 5 | QueryBody `{query, timespan, prefer}` (python `_operations.py:171-176`) | PARTIAL-WIRE-STUB | sentinel.ex:213 reads only `query`; `timespan`/`prefer` ignored | time-scoped queries return unscoped results |
| 6 | Workspace scoping semantics | DIVERGENT | rows stored under `"#{dcr}/#{stream}/"` (sentinel.ex:113,130) but query filters prefix `"#{workspace_id}/"` (sentinel.ex:214) | a real caller queries by workspace GUID; smalt keys rows by DCR id — any workspace-GUID query sees zero rows; DCR-id queries work only by coincidence of naming |
| 7 | Column typing / PrimaryResult envelope | PARTIAL-WIRE-STUB | sentinel.ex:230-281 | GAP(kql-datetime-dynamic-types-absent) already ledgered in WIRE_PARITY.md:130; all-mixed columns report `"string"` |

## 2. Resource Graph

SDK wire shapes: `azure-mgmt-resourcegraph 8.0.1
operations/_resource_graph_client_operations.py:49` —
`POST /providers/Microsoft.ResourceGraph/resources`; default api-version
`"2021-03-01"` (:42). Request model carries `subscriptions`, `query`,
`options{$top,$skip,$skipToken}`, `facets`
(`models/_models_py3.py:821-822,834`). Response: `count`, `data`,
`totalRecords`, `resultTruncated`, `$skipToken`, `facets`.

smalt: route `post "/providers/Microsoft.ResourceGraph/resources"`
(egress_router.ex:722) → `ResourceGraph.query/3` (resource_graph.ex:32).

| # | SDK field (wire) | State | smalt site | gap |
|---|---|---|---|---|
| 1 | `POST /providers/Microsoft.ResourceGraph/resources` | FULL-WIRE-SUPPORT | egress_router.ex:722 → resource_graph.ex:32 | template exact |
| 2 | api-version | DIVERGENT | resource_graph.ex:16 pins `2022-10-01`; :43-46 reject all else | SDK 8.0.1 default `2021-03-01` (_resource_graph_client_operations.py:42) → every SDK-default call gets `400 InvalidApiVersion` |
| 3 | `options.$skipToken` continuation | FULL-WIRE-SUPPORT | resource_graph.ex:161-163 (options.$skipToken first), 113-127 offset resolution | |
| 4 | `options.$top` / `$skip` | FULL-WIRE-SUPPORT | resource_graph.ex:110-111 | flat `body.$top` also accepted (lenient superset) |
| 5 | `resultTruncated` / `totalRecords` / `count` / `data` | FULL-WIRE-SUPPORT | resource_graph.ex:133-146 | server cap 1000, truncation only at cap |
| 6 | `facets` request/response (models `_models_py3.py:821-822`) | MISSING-UNREGISTERED | never read (do_query touches only subscriptions/query/options, resource_graph.ex:74-157); response never carries `facets` | facet requests silently ignored, 200 returned |
| 7 | `subscriptions` shape validation | FULL-WIRE-SUPPORT | resource_graph.ex:52-72 (nil/list-of-string; else typed 400 InvalidParameter) | |

## 3. APIM Gateway

SDK: `@azure/arm-apimanagement@10.0.0` — 137 operation modules under
`dist/esm/operations/`; service-level paths, e.g. `apiManagementService.js:600,632,664`
(`.../providers/Microsoft.ApiManagement/service/{serviceName}` backup/restore/CRUD),
`api.js:347-397` (`.../service/{serviceName}/apis[/{apiId}]`).

smalt: zero routes. `grep -i "apimanagement" lib/smalt/egress_router.ex
lib/smalt/registry.ex` → no matches; no `/subscriptions/{subscriptionId}/...`
mount anywhere; the router's documented surface is Sentinel/ResourceGraph/
Purview/Event Grid/blob/etc (egress_router.ex:16-18). The N-4
`/api/v1/ingest` analog is an application-layer route, not an APIM emulation
(grep for `v1/ingest` across `lib/` → no APIM-plane route exists; Sentinel
ingest is the DCR route at egress_router.ex:684).

| # | SDK surface | State | smalt site | gap |
|---|---|---|---|---|
| 1 | Service CRUD/backup/restore (`apiManagementService.js:600-749`) | MISSING-UNREGISTERED | none — falls to catch-all 404 | GAP-AUD4-01 |
| 2 | APIs/operations/products/gateways (~135 further op modules) | MISSING-UNREGISTERED | none | GAP-AUD4-01 |

## 4. Cognitive Search

SDK: `@azure/search-documents@13.0.0`. Index management:
`dist/esm/searchIndex/api/operations.js:714,786,820,894`
(`/indexes{?api-version}`, `/indexes('{indexName}')`), plus
`/search.stats` (:678), `/search.analyze` (:640). Documents:
`dist/esm/search/api/operations.js:272`
(`/indexes('{indexName}')/docs/search.post.search`),
:107 (`/docs/search.index`), :236 (`/docs('{key}')`), :351 (GET /docs with
`semanticConfiguration`, `answers`, `captions`, `queryType`, `$filter`...).
Semantic/vector body: `dist/esm/searchClient.js:189-215`
(`semanticSearchOptions`, `vectorSearchOptions`, `semanticErrorHandling`,
`semanticPartialResponseReason`).

smalt: zero routes — no `/indexes` match in egress_router.ex or registry.ex.

| # | SDK surface | State | smalt site | gap |
|---|---|---|---|---|
| 1 | Index CRUD `POST/GET/PUT/DELETE /indexes[('{name}')]` | MISSING-UNREGISTERED | none → 404 | GAP-AUD4-02 |
| 2 | `POST /indexes/{name}/docs/search.post.search` (search/api/operations.js:272) incl. semantic + vector body | MISSING-UNREGISTERED | none → 404 | GAP-AUD4-02 |
| 3 | `POST /docs/search.index`, GET/PUT/DELETE `/docs('{key}')`, suggest/autocomplete | MISSING-UNREGISTERED | none → 404 | GAP-AUD4-02 |

## 5. Purview / Atlas

SDK: `@azure-rest/purview-catalog@1.0.0-beta.5 types/purview-catalog-rest.d.ts`
— 58 `/atlas/v2/...` path literals (grep `path: "/atlas` → 58). smalt mounts
5 atlas routes: egress_router.ex:748 (relationship), 779 (entity), 790
(entity/bulk), 801 (entity/guid/:guid), 810 (lineage/:direction/:guid).

| # | SDK surface | State | smalt site | gap |
|---|---|---|---|---|
| 1 | `POST /atlas/v2/entity` (d.ts:4133, verbs post) | FULL-WIRE-SUPPORT | egress_router.ex:779 → purview_atlas.ex:22-45 | typed 400s; guid mint when absent |
| 2 | `POST /atlas/v2/entity/bulk` (d.ts:4135, verbs get/post/delete) | PARTIAL-WIRE-STUB | egress_router.ex:790 → purview_atlas.ex:51-81 | POST only; the SDK's GET (list-by-guids via query) and DELETE verbs on the same path are unregistered (404) |
| 3 | `GET/PUT/DELETE /atlas/v2/entity/guid/{guid}` (d.ts:4139) | PARTIAL-WIRE-STUB | egress_router.ex:801 (GET only) → purview_atlas.ex:84-93 | PUT (partial update) and DELETE unregistered → 404 |
| 4 | `GET /atlas/v2/lineage/{guid}?direction=&depth=` (d.ts:4228; direction/depth/width are QUERY params, d.ts:3868-3877) | DIVERGENT | egress_router.ex:810 mounts `GET /atlas/v2/lineage/:direction/:guid` — direction IN PATH | template mismatch: SDK-shaped call 404s; direction values also differ (SDK `BOTH\|INPUT\|OUTPUT` uppercase d.ts:3876 vs smalt `~w(input output both)` lowercase purview_atlas.ex:15) → double mismatch. GAP-AUD4-03 |
| 5 | `POST/PUT /atlas/v2/relationship` (d.ts:4233-4234) | PARTIAL-WIRE-STUB | POST at egress_router.ex:748 (end1/end2 → put_edge) | PUT (relationship update) unregistered; response guid echo shape not SDK-checked |
| 6 | `GET /atlas/v2/relationship/guid/{guid}` (route inventory) | MISSING-UNREGISTERED | none → 404 | GAP-AUD4-03 |
| 7 | Classifications / labels / businessmetadata (`/entity/guid/{guid}/classifications`, `/labels`, `/businessmetadata`, d.ts:4137-4152) | MISSING-UNREGISTERED | none → 404 | GAP-AUD4-03 |
| 8 | `uniqueAttribute` entity routes (d.ts:4145-4150) | MISSING-UNREGISTERED | none → 404 | GAP-AUD4-03 |
| 9 | Glossary plane (14 routes `/atlas/v2/glossary*`) | MISSING-UNREGISTERED | none → 404 | GAP-AUD4-03 |
| 10 | Types plane (`/atlas/v2/types/typedefs`, `entitydef/...`, 15 routes) | MISSING-UNREGISTERED | none → 404 | GAP-AUD4-03 |

## Classification counts

- FULL-WIRE-SUPPORT: 8 (Sentinel ingest template/204/api-version gate,
  Sentinel query template, RG route/skipToken/top-skip/response fields/
  subscriptions validation, Purview entity POST)
- PARTIAL-WIRE-STUB: 7 (DCR lazy-create, gzip, QueryBody timespan/prefer,
  KQL column types, bulk verbs, entity-guid PUT/DELETE, relationship PUT)
- DIVERGENT: 3 (sentinel workspace scoping, RG api-version pin vs SDK default
  2021-03-01, atlas lineage template+direction-casing mismatch)
- MISSING-UNREGISTERED: 8 route families across 3 planes (APIM 2 rows,
  Search 3 rows, Purview classifications/uniqueAttribute/glossary/types/
  relationship-GET rows)

## New gaps opened (GAP-XXX)

- GAP-AUD4-01 `apim-plane-absent`: @azure/arm-apimanagement@10.0.0 surface
  (137 op modules) has zero smalt registration. SDK-default callers 404.
- GAP-AUD4-02 `search-plane-absent`: @azure/search-documents@13.0.0 index +
  docs/semantic/vector surface unregistered. SDK-default callers 404.
- GAP-AUD4-03 `atlas-plane-thin`: 53 of 58 SDK atlas routes unregistered;
  lineage template mismatch (direction-in-path vs SDK query-param, plus
  INPUT/OUTPUT/BOTH casing) breaks SDK-shaped lineage calls.
- GAP-AUD4-04 `sentinel-workspace-scoping`: rows keyed by DCR id
  (sentinel.ex:113) but queried by workspace id prefix (sentinel.ex:214) —
  workspace-GUID queries see zero rows; DCR-id queries work only by
  coincidence of naming.
- GAP-AUD4-05 `rg-api-version-pin`: smalt accepts only 2022-10-01
  (resource_graph.ex:16) while SDK 8.0.1 defaults to 2021-03-01
  (_resource_graph_client_operations.py:42) — every SDK-default call 400s.
- GAP-AUD4-06 `sentinel-querybody-partial`: QueryBody `timespan`/`prefer`
  ignored (sentinel.ex:213) — time-scoped queries return unscoped results.

## Falsifiers

- GAP-AUD4-04: `POST /dataCollectionRules/{dcr}/streams/{s}` with
  `{"[{...}]"}`, then `POST /v1/workspaces/{workspace-guid}/query` with the
  same guid — rows: 0. Only a query whose "workspace id" equals the DCR id
  returns rows.
- GAP-AUD4-05: python `ResourceGraphClient` with default config →
  `resource graph query` → smalt answers 400 InvalidApiVersion.
- GAP-AUD4-03: `GET /atlas/v2/lineage/{guid}?direction=BOTH&depth=2` → 404;
  `GET /atlas/v2/lineage/both/{guid}` → 200. SDK casing `BOTH` → smalt 400.
- GAP-AUD4-01/02: any SDK-default APIM or Search client call against the
  8443 mount → catch-all 404.
