# v26.10.20 Wave-6 Work Orders

Every claim derives from a receipt on disk in `receipts/` (standing lines
extracted 2026-10-20). Classification is per each receipt's own standing
line. PARTIAL_ALIVE receipts name their typed deferral — usually tree-wide
strict compile behind sibling churn, resolved by the w6R split and the
w6bk plane fence. The w6p receipt is a post-close stub; its witness
evidence lives in the w6p lane report and w6bk re-verified table legs on
live wire post-fence-fix.

## Capability lanes

| id | surface | standing | receipt |
|----|---------|----------|---------|
| w6R | egress router structural split (BEAM limit fix) | ALIVE | receipts/w6R-router-split.md |
| w6bk | file/table plane reserved-prefix fence (cross-plane shadowing fix) | ALIVE | receipts/w6bk-plane-fence.md |
| w6a | KV key rotation policy face | PARTIAL_ALIVE | receipts/w6a-kv-rotation-policy.md |
| w6ab | KV backup/restore (SMALT-KVB1 codec, keys+certificates) | ALIVE | receipts/w6ab-kv-backup-restore.md |
| w6ac | ARM resource providers (49 admitted types) | ALIVE | receipts/w6ac-resource-providers.md |
| w6ad | Activity Log over real telemetry | ALIVE | receipts/w6ad-activity-log.md |
| w6ae | SB auto-forwarding (ForwardTo + chain-limit dead-letter) | PARTIAL_ALIVE | receipts/w6ae-sb-auto-forward.md |
| w6af | EG advanced filters (15 operators, delivery gating) | PARTIAL_ALIVE | receipts/w6af-eg-advanced-filters.md |
| w6ag | Queue update-message popreceipt parity | PARTIAL_ALIVE | receipts/w6ag-queue-update-message.md |
| w6ah | CheckNameAvailability faces | ALIVE | receipts/w6ah-name-availability.md |
| w6ai | Cosmos feed options (continuation, If-Modified-Since) | PARTIAL_ALIVE | receipts/w6ai-cosmos-feed-options.md |
| w6aj | SB ARM management (queues/topics, real-store delegation) | PARTIAL_ALIVE | receipts/w6aj-sb-arm-management.md |
| w6ak | Blob lease family adversarial audit (D1/D2 fixes) | ALIVE | receipts/w6ak-lease-audit.md |
| w6an | Cosmos defaultTimeToLive (inherit/override/sweep) | ALIVE | receipts/w6an-cosmos-default-ttl.md |
| w6ao | App Config revision history + restore | PARTIAL_ALIVE | receipts/w6ao-appconfig-revisions.md |
| w6ap | Metric alert rules (real accumulator evaluation) | PARTIAL_ALIVE | receipts/w6ap-metric-alerts.md |
| w6aq2 | ARM deployments what-if (Create/Modify/Ignore + tags delta) | ALIVE | receipts/w6aq2-deployments-what-if.md |
| w6au2 | EH ingress quota throttle (429 + Retry-After) | PARTIAL_ALIVE | receipts/w6au2-eh-throttle.md |
| w6av | Blob static website ($web hosting) | ALIVE | receipts/w6av-static-website.md |
| w6aw | Blob soft-delete + versioning | PARTIAL_ALIVE | receipts/w6aw-blob-soft-delete.md |
| w6ax | App Config feature flags (TimeWindow + Targeting) | PARTIAL_ALIVE | receipts/w6ax-feature-filters.md |
| w6ay | Blob service CORS + preflight | ALIVE | receipts/w6ay-blob-cors.md |
| w6az | EH Capture (JSONL divergence documented) | ALIVE | receipts/w6az-eh-capture.md |
| w6b | KV managed storage accounts (CRUD/regenerate/SAS defs) | PARTIAL_ALIVE | receipts/w6b-kv-managed-storage.md |
| w6bb | ARM resource-group export template (validate round-trip) | ALIVE | receipts/w6bb-rg-export-template.md |
| w6bc | KV key gaps (RFC 3394 key-wrap, pagination, attrs) | ALIVE | receipts/w6bc-kv-key-gaps.md |
| w6bd | SB topic subscriptions ARM child face | PARTIAL_ALIVE | receipts/w6bd-sb-subscriptions.md |
| w6be | EG retryPolicy + TTL enforcement → blob DLQ | ALIVE | receipts/w6be-eg-retry-policy.md |
| w6bf | SAS sip/spr constraints (mint/verify) | ALIVE | receipts/w6bf-sas-constraints.md |
| w6bg | Cosmos query-metrics + request-charge | ALIVE | receipts/w6bg-query-metrics.md |
| w6bh | ARM quota/usages over real store counts | ALIVE | receipts/w6bh-quota-usage.md |
| w6bi | ERROR_CODES extractor extension (T9/T10/T11) | ALIVE | receipts/w6bi-errcodes-wave6.md |
| w6bj | Cosmos consistency levels + session-token (LSN) | ALIVE | receipts/w6bj-consistency.md |
| w6bm | Resource Health availabilityStatuses | ALIVE | receipts/w6bm-resource-health.md |
| w6bo | Gates preflight (census/sleep/naming/invariant) | ALIVE | receipts/w6bo-gates-preflight.md |
| w6c | KV certificate issuers + contacts | ALIVE | receipts/w6c-cert-issuers-contacts.md |
| w6e | Blob batch witness + tier-echo defect fix | PARTIAL_ALIVE | receipts/w6e-blob-batch.md |
| w6f2 | Cosmos stored procedures witness close-out | ALIVE | receipts/w6f2-cosmos-sprocs.md |
| w6h | Cosmos resource tokens (users/permissions/authz) | PARTIAL_ALIVE | receipts/w6h-cosmos-resource-tokens.md |
| w6i | ARM deployments face (PUT/GET/LIST/DELETE/validate) | PARTIAL_ALIVE | receipts/w6i-arm-deployments.md |
| w6j | EH consumer groups (router rewiring) | ALIVE | receipts/w6j-eh-consumergroups.md |
| w6j2 | EH consumer groups witness close-out (21/21 legs) | ALIVE | receipts/w6j2-eh-consumergroups.md |
| w6l | App Config kv query faces (filters/continuation) | PARTIAL_ALIVE | receipts/w6l-appconfig-queries.md |
| w6o | Azure Files share/dir/file/range face (wire 41/0) | ALIVE | receipts/w6o-file-share.md |
| w6p | Azure Table Storage face (stub receipt; wire re-verified by w6bk) | PARTIAL_ALIVE | receipts/w6p-table-storage.md |
| w6s | App Insights Breeze ingest | PARTIAL_ALIVE | receipts/w6s-app-insights.md |
| w6t | Registrar pass 2 + ERROR_CODES extractor fix | ALIVE | receipts/w6t-registrar-pass2.md |
| w6u | SB SDK divergences F1/F2 (KD-120/121 closed) | ALIVE | receipts/w6u-sb-f1f2.md |
| w6v | KD-112 KD-COVERS token landing | PARTIAL_ALIVE | receipts/w6v-kd112-flip.md |
| w6v2 | KD-112 post-token re-witness + flip confirmation | ALIVE | receipts/w6v2-kd112-flip.md |
| w6x | EH Schema Registry (+ post-split delegator re-landing) | ALIVE | receipts/w6x-eh-schema-registry.md |
| w6y | Azure DNS zones + record sets | ALIVE | receipts/w6y-dns-zones.md |
| w6z | EH checkpoint/ownership store over real BlobStorage | ALIVE | receipts/w6z-eh-checkpoint-store.md |

53 wave-6 receipts: 33 ALIVE + 20 PARTIAL_ALIVE.
