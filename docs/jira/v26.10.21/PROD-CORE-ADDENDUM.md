# ARD Addendum: Smalt v26.10.21 Production Core & Host Substrate Compatibility Plane

Standing: OPERATOR-CHARTER (measured standing accrues via Chicago courts + receipts; aspirational numbers are operator-asserted until their court lands)
Context: full · Date: 2026-10-21

## 1. Executive Directive

All production-grade capabilities land directly in the **Smalt v26.10.21 core substrate** (no commercial fork). Four compatibility pillars:

1. **State Persistence & Periodic Epoch Evacuation** — async segmented WAL from the `{write_concurrency, :auto}` ETS plane to cold blob/disk.
2. **Deterministic Cold Attestation & Confidential Hardware Handshakes** — SEV-SNP / TPM 2.0 roots of trust with loopback dev fallback.
3. **Dual-Interface Ingress Multiplexing** — wire-compatible REST/AMQP (:8443, :8081, :5672) side-by-side with the in-process POWL 2.0 engine (2–74 µs measured, `tmp/bench/powl-native-face.jsonl`).
4. **Autonomous Cloud-Fault Injection (`:prod_sim`)** — parameterized rate limits, partition splits, retry storms.

## 2. Compatibility Specifications

### AR-PROD-01: Asynchronous Epoch Journaling (Non-Blocking WAL)
Dual-tier: memory-resident ordered-set ETS primary; writes emit async append-only segment deltas to `Smalt.Storage.Journal` (lock-free ring, flush every T=500ms or N=10k ops to NVMe/blob).
**Gate**: 20k concurrent mutations — P99 point-read ≤1.1ms wire / ≤10µs POWL; zero lost transactions across kill -9.

### AR-PROD-02: Deterministic Snapshot Recovery & Compaction
Background compaction prunes superseded versions; snapshots are compressed binaries with SHA-256 manifests; boot loads sealed base + tail delta before opening listeners.
**Gate**: cold recovery ≤3.0s on 100k items (falsifier: >5s or checksum divergence).

### AR-PROD-03: Hardware Attestation Extension for Key Vault
`/attestation/report` endpoint; SEV-SNP (`/dev/sev-guest`) / TPM 2.0 quote over the BEAM release digest; local fallback returns `x-ms-attestation-status: simulated` (never silent).
**Gate**: verifiable quote on enclave; clean typed fallback in dev (falsifier: quote fails external verification).

### AR-PROD-04: Sovereign Ingress Policy Filter (Poka-Yoke L3)
Fail-closed wire filters: mandatory `x-ms-client-encryption-key-id` on sensitive writes; immutability/retention lock on deletes; mandatory `x-ms-meta-owner`/`-retention-tier` tags.
**Gate**: 100% rejection of unencrypted/untagged compliance writes (falsifier: any unencrypted payload admitted).

### AR-PROD-05: In-Process Direct POWL Dispatch
Native `Smalt.POWL2.Executor` / pipeline invocation retains the full transactional contract (SHACL, Registry.lock CAS, OCEL Merkle) at 2–74µs.
**Gate**: 4-step settlement P99 ≤100µs (falsifier: >200µs) — POWLBENCH measured 74µs p99 execute-only: **within gate on the landed evidence**.

### AR-PROD-06: Cloud Reality Simulator (`:prod_sim`)
`SMALT_MODE=prod_sim` injects: 10k RU/s token-bucket ceilings (Azure-standard 429 + retry-after), 4–15ms network jitter, KV 2000-ops/10s limits.
**Gate**: SDK backs off and recovers across 9 attempts (falsifier: hang or node crash).

## 3. Work Orders (5 stages)

| WO | Stage | Deliverable |
|---|---|---|
| PROD-1 | WAL foundation | `Smalt.Storage.Journal` ring buffer + segment flush; CAS non-blocking during writes |
| PROD-2 | Ingress hardening | envelope-encryption + tagging filters in router heads; WORM policy enforcement |
| PROD-3 | Native POWL exposure | client bindings for in-process dispatch; unified Merkle sealing wire+native |
| PROD-4 | Attestation bridge | SEV-SNP/TPM quote in PRD-KV; simulated fallback headers |
| PROD-5 | `:prod_sim` | token-bucket 429 + jitter shims; CI courts proving client backoff survival |

## 4. Cross-Language Verification Protocol

Elixir implementations run integration tests against the Erlang reference modules: (1) journal frames written by either language load via `recover_state/2` with identical reconstruction + matching SHA-256; (2) missing envelope keys crash fail-closed (`exit({refusal_andon, ...})`), never a formatted map; (3) under `:prod_sim`, SDKs complete their backoff loops without dropping links.

## 5. Reference Implementations

The operator's five canonical Erlang modules (`smalt_journal`, `smalt_recovery`, `smalt_ingress_filter`, `smalt_attestation`, `smalt_prod_sim`) are the charlatan-proof specification: implementing agents write Elixir against these mechanics and prove conformance by the cross-language protocol above.

**Typed notes on the reference code (coordinator)**: `smalt_prod_sim.enforce_cloud_throttling/2` contains a `timer:sleep(Jitter)` on the request path — that is a deliberate latency-injection mechanism (the SLEEP-CLASS is CONTRACT: the jitter IS the simulated product behavior, invoked only under `:prod_sim`); port it to Elixir with the `# SLEEP-CLASS: CONTRACT` annotation. `smalt_recovery.parse_and_load/3` uses `binary_to_term/1` without `[:safe]` — snapshots are self-produced, but the ARMSTRONG census class flags it: port with `[:safe]` and a typed refusal on unsafe-term failure.

## Boundary Audit (coordinator, 2026-10-21 — post SQL-ingestion wave)

Per the separation-of-concerns directive: **the boundary holds at the code level.** `lib/smalt` carries zero duckdb code dependencies — no mix dep, no NIF, no duckdb ops in the wasm worker, zero `Smalt.Wasm.Bridge` references in the executor's admission path. The three grep hits (sql_ingest.ex, graphlaw/sql_shape_gen.ex, wasm/worker.ex historically) are doc comments describing interfaces with *external* duckdb (the converter's documented fallback path; duckdb DESCRIBE output parsed as an external input format) — interface documentation, not linkage.

The clean topology as implemented: **smalt emits** (OcelNdjson event streams + PROD-1 journal when landed) → **graphlaw mounts** (register_parquet_view / duckdb_eval over the emitted artifacts) → **frozen-duckdb executes** inside graphlaw's process. SQL-ingestion waves (SQLD-2/3/4, GLD-1/2/3) all preserve this: converters and mappers live in smalt, the analytical engine never crosses the boundary.

One scoped exception documented: `lib/smalt/graphlaw/sql_shape_gen.ex` parses duckdb `DESCRIBE` output — an input-format adapter at the boundary surface (graphlaw's shape vocabulary, applied to duckdb's describe format), not an engine dependency. Same class as parsing any external tool's output.
