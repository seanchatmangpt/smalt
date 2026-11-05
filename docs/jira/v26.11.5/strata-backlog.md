# Strata Charter Gap Backlog (v26.11.5)

Standing: PARTIAL — cited receipts verified where checkable; unverified
claims marked as-of-date; gaps registered as wave seeds, not claims.

Derived from the Strata working-backwards charter review (2026-11-04). The
charter is backlog, not status. Each row below is a registered wave seed,
admitted only after its falsifier runs on an exact subject.

## Verified this session (receipt pointers)

| Claim | Receipt | Standing |
|---|---|---|
| AoQ chain hot-path fold (`AoqChain::append` unification) | cgap `8ccb43d0` (+ ERRATA-2 `ff10da29`) | ALIVE (commit verified in cgap log) |
| Slab NIF surface (open/frame/window/stamp/lease/sync) | cgap `aq_slab.rs`, C8 receipt this wave | PARTIAL_ALIVE (16/16 lib tests; contract-court lease leg BLOCKED on owner-lane poll inversion) |
| chachaSeal 4→1 / chachaOpen 3→1 alloc reduction | arcus alloc(l33) `e47f79a` | ALIVE (commit form verified; per-op counts cited from commit message) |
| UDS transit probe hardening | arcus flight(l30) `47f351e` | ALIVE (commit form verified; 55,411 trips/sec cited number NOT pinned to a receipt — UNVERIFIED) |
| Framing law + header layout (AOQ1/CRC/typed refusals) | smalt C6 receipt (24/24 framing court) | PASS |
| Arrow substrate v1 (sealed registry + court ladder) | smalt C3 receipt (30/30) | PASS |
| Datagram face + send_batch | smalt C5 receipt (16/16) | ALIVE |
| bin_opt_info gate + non-vacuity court | smalt C1 receipt + `91bc8f4e` | PARTIAL_ALIVE (2 real worker.ex violations red — repair queued peer-side as L41) |

## Registered gaps (wave seeds — none admitted yet)

| # | Gap | Charter surface | Falsifier shape |
|---|---|---|---|
| S1 | Turnstile contract: refusal at exactly frame 4,097, `BUSY 0x4347A003` constants | unnamed in landed specs | court: 4096 passes, 4097 refuses with exact code; mutation flips |
| S2 | 0 payload B/op → measured receipt | spec-scoped only | C7 alloc bench (tprof call_memory + zero-GC fence) — lane in flight this wave |
| S3 | Membrane stratum (enif resource-binary routing, off-heap queues, 0 allocs/round-trip) | smalt NIF seam is Stub | binds to C8's landed aq_slab surface; `Smalt.Aoq.Nif.Beam` impl of the NifHolder behaviour |
| S4 | Wasm arena stratum | greenfield | define subject first: which runtime (wasmex is in-tree), which arena ops, falsifier = alloc delta vs Elixir baseline |
| S5 | arcus UDS soak 55,411 trips/sec | number unpinned | re-run the l30 probe with JSONL receipt emission (bench lanes write only their own result file) |
| S6 | ML-KEM-768 handshakes | greenfield | stdlib/rust CryptoPadding-free KEM leg + interop vector court |
| S7 | Statutory docket surface (ASC 450/SOX 404/EU AI Act/FRE 902) | greenfield | scope check first: is this an ontology/vocabulary lane (public-cloud-ontology precedent) or a feature claim? Decide before building |
| S8 | QUIC-as-system-bus | phase 2 per landed decision record | unchanged — quinn ≥0.11.15 in NIF boundary; not started |

## Multi-hyperscaler expansion (1/1/27 target — registered 2026-11-05)

**ARCHITECTURE RULING (operator, 2026-11-05):** the multi-hyperscaler faces
(Kinesis/SQS/PubSub) are owned by **arcus** (the peripheral membrane) —
`internal/ingress/aws` + `internal/ingress/gcp` are the strategic faces
(SigV4 in `ingress/auth`, adapter opTable aws-kinesis/aws-sqs/gcp-pubsub.*
rows wired, REST-shaped json-envelope transport — no gRPC transport needed
for the PubSub 80/20). smalt-side faces (KinesisRoutes, egress/sqs/,
pubsub_grpc/) are **BEAM emulator-parity twins** (EH-REST precedent):
kept, receipted, no further investment. GCP face: arcus REST form
dissolves the F-P2/Bandit-h2/grpcio transport question entirely.

Scope: AWS (MSK/Kinesis/SQS), Azure (EH/SB — largely landed), GCP (Pub/Sub
gRPC/managed Kafka) unified behind the Arcus membrane → AoQ fabric → smalt
substrate. Azure faces are ALIVE; AWS Kafka-wire is the same surface as the
smalt Kafka face; the net-new surfaces are:

| # | Gap | Blueprint surface | Ground-truth delta | Falsifier shape |
|---|---|---|---|---|
| S15 | GCP Pub/Sub gRPC face | gRPC ingress dialect | zero code anywhere (no gRPC server in fleet; Pub/Sub = zero hits) | real google-cloud-pubsub client roundtrip vs emulated face, byte/semantic parity court |
| S16 | Kinesis REST face | Kinesis REST ingress | zero code (Azure EH REST exists as the template) | real boto3 Kinesis client roundtrip + RecordBatch transmute fidelity court |
| S17 | SQS face | SQS REST ingress | zero code | real boto3 SQS client + queue-semantics divergence rows |
| S18 | Unified multi-dialect listener | one Arcus adapter surface → AoQ | arcus ingress/egress are empty scaffolds; adapters are admission tables | per-dialect roundtrip through ONE membrane boundary to the AoQ kernel |
| S19 | frozen-duckdb live SQL over raw logs | sub-15ms p99 vector scans | duckdb exists ONLY as popcorn_demo spike with frozen compression benches; no SQL-over-log path | latency court: sealed segment → SQL → result, p99 fence vs measured baseline (no invented 15ms) |
| S20 | io_uring/O_DIRECT NVMe log | direct columnar appends | ZERO code, PROPOSED-only, structurally impossible on darwin/APFS — Linux-only lane with a platform gate | Linux runner + append-throughput court; darwin keeps datasync (honest scoping, never claimed) |
| S21 | Cross-cloud replication fabric | MirrorMaker-class over AoQ/QUIC | no replication code; QUIC server role not built (see S8/QUIC phase-2) | two-node AoQ replication roundtrip with BLAKE3 chain continuity across nodes |
| S22 | AHDCLT statutory defense | fail-closed SHACL + self-executing receipt ledger on protocol drift | SHACL engine dev/test-only (WO-10), ledger chains sha256 (retarget planned), S7 scope-check still open | seeded schema-drift injection → typed refusal + chained receipt, mutation flips |

Cross-refs: S13 (translation tax, measured-only) applies to every new face;
S3 (membrane NIF) and S8 (QUIC phase-2) are prerequisites for S18/S21.
Admission law unchanged: none of these are claims — each admits only via
its falsifier on an exact subject. Date "1/1/27" is a target, not a
receipt; no artifact on disk asserts schedule feasibility.

## Wave seeds S9–S14 (registered 2026-11-04, v26.11.6 wave finale — append-ordered; S1–S22 unchanged)

Propose-only seeds minted from the v26.11.6 wave findings. None is
admitted; each admits only via its falsifier on an exact subject.

| # | Gap | Source (wave finding) | Falsifier shape |
|---|---|---|---|
| S9 | QUIC server role (cgap server table + staged dylib rebuild; smalt roundtrip + real-load court arms flip) | L4 BLOCKED section (`v26.11.6/receipts/lane4-aoq-quic-nif.md`), KD-192 | loopback roundtrip + corrupted-CA refusal flip on a real engine bind |
| S10 | cgap NIF export law (`#[no_mangle]` on ErlNifFunc entries, or rustler adoption) | KD-192 (cgap-side fix) | dlsym resolves every ErlNifFunc entry; `bad_lib` load refusal disappears |
| S11 | G2 court test 5 tautology (indented heredoc drops the type decl; OOV refusal carried by the wrong component) | KD-193 (`v26.11.6/receipts/lane16-aoq-rdf-projector.md` FINDING) | de-indent the corpus or assert the component id; shim removal of `sh:closed` flips test 5 RED |
| S12 | real-client census (librdkafka / Java client legs against the Kafka face) | wave +1 hardening plan (`../v26.11.6/README.md` sequencing) | real-client produce/consume roundtrip courts; KD-row burn-down measured |
| S13 | bench receipts for unpinned perf claims (arcus 55,411 trips/sec; Kafka-face throughput) | S5 residue + wave tax table (UNMEASURED rows) | bench lanes emit jsonl receipts; claims pin to receipts or are deleted |
| S14 | arcus L14 Seal-flag / gitpack-0x08 cgap ticket closure | KD-195 (arcus `l14-kafka-adapter.md`) | cgap ticket closes with a receipt; smalt-side KD row flips receipt-gated |

Cross-refs: S10 is the cgap-side prerequisite for S9; S12/S13 are the
wave +1 hardening pair; S14 closes the only arcus-side open item.


## Multi-hyperscaler 80/20 wave sequencing (registered 2026-11-05)

80/20 = produce/consume loops that don't crash, auth that authenticates,
offsets that survive restart, each cloud's dominant wire face. Excludes
transactions, exactly-once, compaction, KIP-482, replication fabric.

- Wave drain (v26.11.6): Azure ≈ parity (L2 remaining), AWS Kafka face
  demoable (L1/L2/L6/L10 + L7/L12 underneath). QUIC phase-2 NOT required
  for 80/20 wire parity — phase-1 UDP/TCP suffices.
- Wave +1: hardening — real-client census (librdkafka/Java), KD-row
  burn-down, bench receipts converting perf claims, durable-offset
  restart-under-load proof.
- Waves +2/+3: Kinesis REST (S16) then SQS (S17) — template off EH-REST;
  parallelizable.
- Wave +4: GCP Pub/Sub gRPC (S15) — the gRPC transport surface is the
  long pole, not the protocol mapping.
- Gate law: calendar ("1/1/27") does not admit; measured KD-row burn-down
  does. Risk concentration: shared substrate (durable offsets, SHACL-in-prod)
  over per-face protocol surface.

## Chatman Equation rendering note

`ΔS_admitted + Φ_lease ≡ R_receipt mod Σ_PQC` is a stylization. The
machinery-mapped form is the FAQ's three-term gate: admitted state
(sealed registries, frame tables), live lease (cursor atomics ledger),
receipt (BLAKE3-chained receipts) — all three partially landed this wave
(C3/C6/C8). Press-release form stays out of governing docs.
