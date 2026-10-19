# Operation Sovereign Midnight — capstone burn spec (landed 2026-10-19)

Enterprise archetype: G-SIB EOQ cross-border settlement freeze ($4.2T) under
SEC/DOJ legal hold + split-brain failover + throttling retry storm. 21 surfaces,
4 planes + governance ring, OCEL 2.0 + BeamPM.Art72Conformance judge, 50 cycles
with kill -9 every 10th. Full phase spec in the operator's original document
(preserved in session; this file is the coverage map + gap register).

Refresh 2026-10-18: all 18 test bodies run untagged (`:sovereign_gap` tag retired;
`mix test test/azsim/sovereign_midnight/sovereign_midnight_test.exs` → 18 tests,
0 failures — i29-sovereign-gap-triage.md + i29-midnight-map-refresh.md).

## Phase coverage vs current tree

| Phase | Surface | Coverage | Evidence |
|---|---|---|---|
| 1 Identity | Entra STS/JWKS, KD-15+SKR, crypto wrap/sign | PARTIAL | bearer.ex sub-codes + KD-15 (azb-08); 1-bit-flip refusal exercised by test 1.3 (triage receipt); JWT expiry-race injector MISSING |
| 2 Control | APIM mTLS X-ARR-ClientCert + token-bucket 429 | MISSING | arm_throttle 429 exists; X-ARR-ClientCert + spoof-injector absent (grep: 0 hits) |
| 2 Control | ARM hierarchy + ETag 16-way race + LRO sweeper kill | COVERED | cosmos_etag gate, AZB-14 storm, LRO Notifier one-writer (azb-06/09/14); test 2.2 16-way NSG ETag race settles 16/16 |
| 2 Control | Policy 403 + Deployments 202 + mid-flight sweeper murder | PARTIAL | PolicyRbac 12/0 + test 2.3 deny→PolicyViolation (triage); cancel-race injector MISSING |
| 3 Messaging | SB PeekLock lock-lost ghost + dedup storm + 4096 wall | PARTIAL | capacity gate + F12/F18 fixed; typed `{:error, :lock_lost}` token-scoped compare-and-settle landed (queue_store.ex:334-352, i29-sovereign-gap-triage.md); test 3.1 (flake 1/4 per triage, deterministic in refresh run) |
| 3 Messaging | EH partition steal + checkpoint resume | PARTIAL | fixed partitions + azb-20 attach + test 3.2 send/receive/checkpoint; mid-stream detach/resume injector MISSING |
| 4 Data | AppConfig CAS 10-way + Sync-Token | COVERED | appconfig_etag_cas gate (6/6 receipts) |
| 4 Data | Cosmos CAS/unique/RU-429 | PARTIAL | etag gate + AZB-06 CAS; RU-429 x-ms-retry-after injector MISSING |
| 4 Data | Blob WORM/LegalHold/snapshot/range | COVERED | blob_worm gate + AZB-06 (WORM tamper, snapshot) |
| 4 Data | **Queue Storage (popreceipt, visibility, stale-replay)** | **MISSING** | grep: 0 hits for popreceipt/VisibilityTimeout/"queue storage" in lib/smalt — new data-plane surface |
| 4 Data | Event Grid batch 400 + DLQ blob spillover | PARTIAL | Event Grid engine (azb-07) at-least-once; DLQ-blob spillover MISSING (messaging/event_grid.ex: 0 DLQ/blob hits) |
| 5 Forensics | Wasm seal + mid-seal kill + bytecode fuzz | COVERED | supervised restart (azb-22b fixing ring RED) |
| 5 Forensics | Confidential Ledger Merkle tamper probe | COVERED | ledger_chain gate |
| 5 Forensics | Purview Atlas lineage | COVERED | atlas probes (azb-20 matrix) |
| 5 Forensics | Resource Graph KQL subset | COVERED | route family landed: egress_router.ex:1311 `POST /providers/Microsoft.ResourceGraph/resources` → ResourceGraph.query/3 (data_plane/resource_graph.ex; runtime_contracts/resource_graph_query.ex) |
| 5 Forensics | Sentinel incident ingestion | COVERED | sentinel.ex ingest |
| 5 Forensics | MCP :9545 blast-radius (AZB-09 proof) | COVERED | plane supervisors (azb-09) |
| Judge | OCEL 2.0 + BeamPM conformance | PARTIAL | burn_to_ocel2.py; Art72 gate landing with AZB-24 |

## Gap register (build order for v26.10.19)
G1. MISSING — Queue Storage data plane (popreceipt/visibility/stale-replay) — new surface (grep: 0 hits in lib/smalt)
G2. MISSING — X-ARR-ClientCert mTLS gateway termination + spoof injector — new (grep: 0 hits)
G3. MISSING — Event Grid DLQ blob spillover — extends azb-07 engine (event_grid.ex: no DLQ path)
G4. MISSING — Split-brain regional failover plane — new architecture (grep: 0 hits)
G5. NARROWED — Injectors only: JWT expiry race, 1-bit ciphertext flip, RU-429 retry-after, EH mid-stream detach/resume, cancel race (lock-lost 410 closed by queue_store.ex token-scoped settle — i29-sovereign-gap-triage.md)
G6. CLOSED — AZB-20 gap-6 ResourceGraph route family landed (egress_router.ex:1311); residual AZB-20 items (control-only ARM 500s, identity listener, cosmos bulk-upsert) tracked outside this register

## Sequencing
AZB-23/24 close v26.10.18 first; Sovereign Midnight = v26.10.19+ burn capstone,
built on the burned-in container foundry (AZB-13/14/17/18) this window landed.
