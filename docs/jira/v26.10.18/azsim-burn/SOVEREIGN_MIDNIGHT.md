# Operation Sovereign Midnight — capstone burn spec (landed 2026-10-19)

Enterprise archetype: G-SIB EOQ cross-border settlement freeze ($4.2T) under
SEC/DOJ legal hold + split-brain failover + throttling retry storm. 21 surfaces,
4 planes + governance ring, OCEL 2.0 + BeamPM.Art72Conformance judge, 50 cycles
with kill -9 every 10th. Full phase spec in the operator's original document
(preserved in session; this file is the coverage map + gap register).

## Phase coverage vs current tree

| Phase | Surface | Coverage | Evidence |
|---|---|---|---|
| 1 Identity | Entra STS/JWKS, KD-15+SKR, crypto wrap/sign | PARTIAL | bearer.ex sub-codes + KD-15 (azb-08); expiry race + 1-bit-flip injectors MISSING |
| 2 Control | APIM mTLS X-ARR-ClientCert + token-bucket 429 | MISSING | arm_throttle 429 exists; X-ARR-ClientCert + spoof-injector absent (grep: 0 hits) |
| 2 Control | ARM hierarchy + ETag 16-way race + LRO sweeper kill | COVERED | cosmos_etag gate, AZB-14 storm, LRO Notifier one-writer (azb-06/09/14) |
| 2 Control | Policy 403 + Deployments 202 + mid-flight sweeper murder | PARTIAL | PolicyRbac 12/0; cancel-race injector MISSING |
| 3 Messaging | SB PeekLock lock-lost ghost + dedup storm + 4096 wall | PARTIAL | capacity gate + F12/F18 fixed; lock-lost 410 typed face MISSING |
| 3 Messaging | EH partition steal + checkpoint resume | PARTIAL | fixed partitions + azb-20 attach; mid-stream detach/resume injector MISSING |
| 4 Data | AppConfig CAS 10-way + Sync-Token | COVERED | appconfig_etag_cas gate (6/6 receipts) |
| 4 Data | Cosmos CAS/unique/RU-429 | PARTIAL | etag gate + AZB-06 CAS; RU-429 x-ms-retry-after injector MISSING |
| 4 Data | Blob WORM/LegalHold/snapshot/range | COVERED | blob_worm gate + AZB-06 (WORM tamper, snapshot) |
| 4 Data | **Queue Storage (popreceipt, visibility, stale-replay)** | **MISSING** | grep: 0 hits in lib/smalt — new data-plane surface |
| 4 Data | Event Grid batch 400 + DLQ blob spillover | PARTIAL | Event Grid engine (azb-07) at-least-once; DLQ-blob spillover MISSING |
| 5 Forensics | Wasm seal + mid-seal kill + bytecode fuzz | COVERED | supervised restart (azb-22b fixing ring RED) |
| 5 Forensics | Confidential Ledger Merkle tamper probe | COVERED | ledger_chain gate |
| 5 Forensics | Purview Atlas lineage | COVERED | atlas probes (azb-20 matrix) |
| 5 Forensics | Resource Graph KQL subset | PARTIAL | resource_graph.ex exists; AZB-20 gap-6: route family absent |
| 5 Forensics | Sentinel incident ingestion | COVERED | sentinel.ex ingest |
| 5 Forensics | MCP :9545 blast-radius (AZB-09 proof) | COVERED | plane supervisors (azb-09) |
| Judge | OCEL 2.0 + BeamPM conformance | PARTIAL | burn_to_ocel2.py; Art72 gate landing with AZB-24 |

## Gap register (build order for v26.10.19)
G1. Queue Storage data plane (popreceipt/visibility/stale-replay) — new surface
G2. X-ARR-ClientCert mTLS gateway termination + spoof injector — new
G3. Event Grid DLQ blob spillover — extends azb-07 engine
G4. Split-brain regional failover plane — new architecture
G5. Injectors: clock-skew/JWT race, 1-bit ciphertext flip, RU-429, lock-lost 410, cert spoof, cancel race
G6. AZB-20's 9 typed gaps (control-only ARM 500s, ResourceGraph routes, identity listener, cosmos bulk-upsert)

## Sequencing
AZB-23/24 close v26.10.18 first; Sovereign Midnight = v26.10.19+ burn capstone,
built on the burned-in container foundry (AZB-13/14/17/18) this window landed.
