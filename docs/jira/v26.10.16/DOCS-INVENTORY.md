# DOCS-INVENTORY — v26.10.16 ideal docs DAG (first-principles, derived from landed reality)

Derived from: 137 defmodules in lib/smalt/**, 46 distinct Application.get_env(:smalt, ...) keys,
mix.exs package (files: lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md NOTICE.md),
scripts/bootstrap.sh (8-stage chain), Justfile court chain, gates/, scripts/bench/REGISTRY.md,
scripts/shim_court/, docs/reference/kd-register.md, auditor artifacts.

Legend: COVERS = existing file matches landed reality · STALE = exists but drifts · MISSING = no on-disk referent.

## Audience A — HEX CONSUMER

Public module subsystems: arm_gateway (Router/Defaults/LRO/ProviderMatrix — 9443), egress/data_plane
(EgressRouter 8443; BlobService, BlobStorage, ConditionalHeaders, Cosmos, KeyVaultActions, KQL,
PartitionKey, Purview, ResourceGraph, Sentinel, SKR, VaultData), messaging/amqp (Amqp.* + AmqpBroker
5672/5673; EventHubs, EventStream), auth (Bearer, BodyCache, Sas; TLS), affidavit (Seal, WasmEngine,
AffidavitOcel), fin_ops (Calculator), policy/graphlaw (Policy, GraphLaw.*, Registry, SbRules),
metrics/spc (Metrics, Spc.Drift, RollingCounters, SemConv.Registry), telemetry/ocel (Ocel.*,
Telemetry.* incl. OcelEmitter, OcelNdjson, CourtOcel, EnclaveOcel), enclave (Doctor, Engine, Hcl,
Lifecycle, Remediations, State), security/trust (Attestation, ConfidentialLedger, LedgerWriter,
ReceiptSigner, TrustProfile.*), contracts/projection (RuntimeContracts.*, Projection.*, Semantic.*,
Store.DetsMirror, CosmosSql, PPlan.Task, Hw.*, Mcp.*, Dspy.Remediation, AshExtension.*).

| ID | Doc | Coverage |
|---|---|---|
| A1 | README golden path + ports | COVERS |
| A2 | Config reference: all 46 :smalt app-env keys + defaults + env overrides | STALE (fragments only; no single env-key reference) |
| A3 | Wire API reference (ARM surface, Registry types, api-version eras, actions) | STALE |
| A4 | Typed-refusal/error-code vocabulary (ERROR_CODES.md + refuse atoms + uppercase families) | COVERS in repo; MISSING from hex package (not in files:) |
| A5 | AMQP/SB + EH protocol guide (CBS/SAS, locks, DLQ, KD-68/70/71/77) | STALE (WIRE_PARITY is a gap register, not a consumer guide) |
| A6 | Affidavit/evidence guide | COVERS (verify against wasm_pin_path default) |
| A7 | Enclave/two-tier + trust-profile guide | COVERS |
| A8 | SemConv/telemetry contract | MISSING (source: lib/smalt/telemetry/sem_conv/registry.ex) |
| A9 | Hex packaging metadata | COVERS as record (PUBLISH_RECORD); none ships in-package |

## Audience B — CLONE DEV

| ID | Doc | Coverage |
|---|---|---|
| B1 | Bootstrap guide (8 stages, exit semantics, idempotence) | STALE (FIRST_RUN/DEV_ENV parity check needed) |
| B2 | Ports-and-planes law | COVERS (ports-and-planes.md) |
| B3 | Courts ladder (court chain, court_x2, verify_all) | STALE |
| B4 | Invariant gates (7 gates + receipts) | MISSING |
| B5 | Shim courts (28+ courts, lib.sh contract, KD-COVERS convention) | COVERS (verify completeness) |
| B6 | Bench registry + lanes | COVERS (version stamp STALE) |
| B7 | KD register + flip protocol | COVERS |
| B8 | Wrap/release sequence (release.sh + court-x2 + publish-dry) | MISSING as a single dev doc |
| B9 | Dev loop / substrate lifecycle | COVERS |
| B10 | Doctor + receipts DoD | STALE |

## Audience C — AUDITOR

| ID | Doc | Coverage |
|---|---|---|
| C1 | Receipts ledger/index (receipt_index.py, R8 drift gate) | COVERS |
| C2 | Publish record (TYPED-BLOCKED, B1-B6) | COVERS |
| C3 | Wrap ledger / parks | COVERS |
| C4 | Court post-mortem / failure forensics | MISSING (logic only in court_x2.sh) |
| C5 | KD canonical register + flip audit trail | COVERS |
| C6 | Receipt-standing taxonomy + minting law | STALE |

## DAG edges (rewrite spec)
- A2 ← application.ex + config/config.exs (generated, fenced like ERROR_CODES)
- A4 ← gen_error_codes.py + telemetry refuse codes (single-sourced, fenced)
- A3 ← Smalt.Registry + arm_gateway/router.ex + capabilities.json
- A5 ← WIRE_PARITY + KD register (consumer-facing projection, no GAP tokens)
- A8 ← Telemetry.SemConv.Registry (generated)
- B1 ← bootstrap.sh stage table; B3 ← Justfile court chain; B4 ← gates/*; B8 ← release.sh + publish_dry.sh
- C4 ← court_x2.sh judge_log/diff semantics; C6 ← receipt_index.py standing scan
- Packaging: A4 + A2 must be decided in/out of mix.exs files: — consumer-facing docs ship in README
  or join files:.

## Summary

| Audience | COVERS | STALE | MISSING | Total |
|---|---|---|---|---|
| A hex consumer | 3 | 3 | 3 | 9 |
| B clone dev | 4 | 4 | 2 | 10 |
| C auditor | 3 | 1 | 2 | 6 |
| Total | 10 | 8 | 7 | 25 |

Highest-leverage MISSING: A2 (env-key reference), A4-in-package (error codes not shipped), A8
(semconv contract), B4 (invariant gates), B8 (wrap sequence), C4 (court post-mortem), C6
(receipt-standing taxonomy).
