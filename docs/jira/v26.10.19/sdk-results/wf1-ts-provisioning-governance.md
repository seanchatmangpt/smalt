# External workflow receipt: wf1-provisioning-governance (ts)

Workflow: wf1-provisioning-governance
Lang: ts
Window: v26.10.19
SUBJECT_SHA: b847c020ee6b0a7ef426e27379f960228932feb0
Profile: primary-tier external suite (official Azure SDKs; surfaces: arm, resource-graph, purview-atlas, appconfig, cap:eventgrid-topics-arm, cap:appconfig-kv)
Generated: 2026-10-19T18:36:28.048977+00:00

## Cell tags

resource-graph:create: resource-graph/create PASS
arm:dead-port-plane-check: arm/dead-port-plane-check PASS
resource-graph:dead-port-plane-check: resource-graph/dead-port-plane-check PASS
purview-atlas:dead-port-plane-check: purview-atlas/dead-port-plane-check PASS
appconfig:dead-port-plane-check: appconfig/dead-port-plane-check PASS
arm:policy-def-create: arm/policy-def-create PASS
arm:policy-assignment-create: arm/policy-assignment-create PASS
arm:vnet-put-201: arm/vnet-put-201 PASS
arm:storage-lro: arm/storage-lro PASS
arm:policy-deny: arm/policy-deny PASS
resource-graph:tag-merge: resource-graph/tag-merge PASS
resource-graph:tags-null: resource-graph/tags-null PASS
arm:missing-rg-404: arm/missing-rg-404 PASS
resource-graph:missing-rg-404: resource-graph/missing-rg-404 PASS
purview-atlas:missing-rg-404: purview-atlas/missing-rg-404 PASS
appconfig:missing-rg-404: appconfig/missing-rg-404 PASS
resource-graph:delete-lro: resource-graph/delete-lro PASS
resource-graph:gone-404: resource-graph/gone-404 PASS

## Runner output tail

```
rg-404","verdict":"GREEN","detail":"typed 404 ResourceGroupNotFound"},{"name":"rg-delete-lro","verdict":"GREEN","detail":"beginDelete pollUntilDone terminal"},{"name":"rg-gone-404","verdict":"GREEN","detail":"re-GET after delete 404"}]}
{"id":"wf5","checks":[{"name":"arm-429-burst","verdict":"GREEN","detail":"182/200 requests 429'd, retry-after=1"},{"name":"arm-429-typed-code","verdict":"GREEN","detail":"error.code=TooManyRequests status429x182"},{"name":"arm-429-sdk-observability","verdict":"GREEN","detail":"SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)"},{"name":"dead-port-plane-check","verdict":"GREEN","detail":"dead port typed failure (TypeError)"}]}

== VERDICT TABLE ==
-- wf1: child exit=0
   [GREEN] rg-create — rg wf1-608dab56 created
   [GREEN] dead-port-plane-check — dead authority typed as real transport failure (Error)
   [GREEN] policy-def-create — definition ts-deny-608dab56 PUT by-id resolved
   [GREEN] policy-assignment-create — assignment at RG scope by-id resolved
   [GREEN] vnet-put-201 — vnet wf1-vnet-608dab56 provisioningState=Succeeded
   [GREEN] storage-lro — LRO terminal, provisioningState=Succeeded
   [GREEN] policy-deny — westus2 PUT refused 400 PolicyViolation
   [GREEN] rg-tag-merge — tags after PATCH merge: {"env":"ts-court"}
   [GREEN] rg-tags-null — tags after PUT full-replace with empty tags: null
   [GREEN] missing-rg-404 — typed 404 ResourceGroupNotFound
   [GREEN] rg-delete-lro — beginDelete pollUntilDone terminal
   [GREEN] rg-gone-404 — re-GET after delete 404
-- wf5: child exit=0
   [GREEN] arm-429-burst — 182/200 requests 429'd, retry-after=1
   [GREEN] arm-429-typed-code — error.code=TooManyRequests status429x182
   [GREEN] arm-429-sdk-observability — SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)
   [GREEN] dead-port-plane-check — dead port typed failure (TypeError)
[run-all] done in 7.0s exit=0
```
