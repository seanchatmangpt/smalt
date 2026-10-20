# examples/ wave — lane partition (coordinator: main session, 2026-10-19)

Goal: 8 Fortune-500 archetype examples, each a runnable real-wire harness
against the local substrate (9443/9444/8443/5672/5673), same laws as
`verification/` (official SDKs, env-var endpoints with localhost defaults,
bounded polls on real observables, typed SDK exceptions, no emulator-internal
imports, no fixed sleeps).

**Lane law**: each lane owns ONLY `examples/<name>/**` (harness, README,
receipt). No lane edits `lib/`, `verification/`, gates, or another lane's
dir. Unique lane-scoped runids (`ex<N>-<name>-<ts>`) for all resource names
avoid cross-lane collisions on the shared substrate. The coordinator owns all
git transitions and integration.

| Lane | Dir | Archetype | Surfaces exercised |
|---|---|---|---|
| 1 | examples/bank-ledger-nightly | Bank core-ledger nightly batch | arm, kv, cosmos, blob-worm |
| 2 | examples/retail-order-pipeline | Retail order pipeline | sb, eh, cosmos |
| 3 | examples/healthcare-archive | Healthcare compliance archive | blob-worm, capabilities still in flight → typed XFAIL/skip-until-landed markers |
| 4 | examples/telco-event-grid | Telco event-ingestion grid | eh, sentinel/kql, resource-graph |
| 5 | examples/insurance-governance | Insurance policy governance | policy/RBAC/locks/tags |
| 6 | examples/media-drm-custody | Media DRM key custody | keyvault crypto (rsa-oaep, rs256), kv soft-delete in flight → XFAIL markers |
| 7 | examples/fintech-throttle | Fintech throttling resilience | throttle profile, retry-on-429, CBS claim capacity |
| 8 | examples/saas-provisioning | Multi-tenant SaaS provisioning | arm LRO lifecycle, cascade delete, tags law, atlas |

In-flight capabilities (KV deleted-keys plane, scheduleMessage, snapshot
listing, secrets backup/restore) → write to Azure spec with typed
XFAIL/skip-until-landed markers; flip to full assertions as lanes land.

Integration (coordinator, serialized): run all 8 harnesses green → per-lane
atomic commits → `examples/README.md` index + coverage note mapping each
example's steps to KD/workflows cells → receipts per example.
