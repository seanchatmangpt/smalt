# tickets — v26.10.28 window

One ticket per Topaz roadmap item (T-01…T-16, from
`../TOPAZ_ROADMAP_PARITY_MAP.md`) plus the two defects receipted by the
window's parity lane (T-17, T-18). Every ticket's Definition of Done is
written as the Azure developer's experience using the result — SDK/CLI
calls they already write, behaving the way real Azure behaves.

| id | ticket | verdict | size | depends |
|---|---|---|---|---|
| T-01 | [ACR control plane + Tasks](T01-acr-control-plane-and-tasks.md) | GAP | XL | — |
| T-02 | [Resource pre-seeding](T02-resource-pre-seeding.md) | GAP | M | — |
| T-03 | [Event Grid MCP tool](T03-eventgrid-mcp-tool.md) | PARTIAL | S | — |
| T-04 | [AppConfig KV-refs + change events](T04-appconfig-kvrefs-and-change-events.md) | PARTIAL | M | — |
| T-05 | [KQL: bin/join/mv-expand/cross-workspace](T05-kql-extended-operators.md) | PARTIAL | L | — |
| T-06 | [Redis RESP2 data plane](T06-redis-resp2-data-plane.md) | GAP | XL | — |
| T-07 | [APIM policy execution](T07-apim-policy-execution.md) | PARTIAL | L | — |
| T-08 | [SB: DLQ + scheduled + deferral](T08-servicebus-dlq-scheduled-deferral.md) | PARTIAL | L | — |
| T-09 | [EH: consumer-group epoch](T09-eventhub-epoch-enforcement.md) | PARTIAL | S/M | — |
| T-10 | [Container Instances (control plane)](T10-container-instances-control-plane.md) | GAP/OUT | M | T-01 |
| T-11 | [Functions resource + admin API](T11-functions-resource-and-admin-api.md) | GAP | M | — |
| T-12 | [AMQP chaos injectors](T12-amqp-chaos-injectors.md) | PARTIAL | M | — |
| T-13 | [OpenTofu compatibility](T13-opentofu-compatibility.md) | PARTIAL | S | — |
| T-14 | [Service Health + chaos incidents](T14-service-health.md) | GAP | M | T-12 |
| T-15 | [IaC export (bicep/HCL)](T15-iac-state-export.md) | GAP | M | — |
| T-16 | [SB chained DLQ forwarding](T16-servicebus-chained-dlq-forwarding.md) | GAP (blocked) | M | T-08 |
| T-17 | [DEFECT: snapshot-delete gate not firing](T17-defect-snapshot-delete-gate.md) | DEFECT | S | — |
| T-18 | [DEFECT: blob content-type serving](T18-defect-blob-content-type-serving.md) | DEFECT | S | — |

Recommended pick order for the next window (cheap + receipt-backed first):
T-17, T-18 (defects from this window's receipts) → T-09 → T-13 → T-03 →
T-05 → T-04 → T-08 → T-15; the XL/new-listener items (T-01, T-06) and the
resource-model lanes (T-07, T-10, T-11, T-14) window separately.
