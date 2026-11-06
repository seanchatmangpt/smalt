# CSCT Conformance Register — RFC-0042

Standing: PARTIAL_ALIVE

14-lane Explore sweep 2026-11-05 over smalt/arcus/cgap/ggen-marketplace. Canonical spec:
the RFC-0042 text supplied by the operator 2026-11-05 (§1–§8). In-repo witnesses:
`ADR-PRD-BENCH-26.11.6.md` (§1–§5 + Quiet-Host Law), `ADR-PRD-CSCT-COMBINATORIAL-26.11.6.md`
(80-cell matrix, invariants, acceptance), `cgap/docs/csct/csct-spec.md` (6-stage arc).
Prior typed-down verdict: `receipts/csct-claim-verification-verdict.md` (PARTIAL_ALIVE).

## Legend

Verdict: CONFORMANT (court passes against the requirement) / PARTIAL (executed but a
pinned divergence is stated) / GAP (not met) / NOT-TESTED (never run, reason stated).
Status: OPEN / CLOSED-WITH-EVIDENCE / PROPOSE-ONLY. Table is ground truth over prose.

## Axioms (§3)

| id | Requirement | Verdict | Evidence receipt | Close condition | Status |
|---|---|---|---|---|---|
| CT-01 | Axiom 1 real collaborators | PARTIAL | X13: `scripts/az1/*` real kafka-python-ng; arcus `tests/ingress_py/` real boto3/pubsub; Go `_court_test.go` are hand-rolled twins (lawful falsifiers). `scripts/bench.py:375,411` raw-socket framers are Axiom-1 violations for benchmark claims; 80-cell matrix executes no code; azure-eventhubs dialect is a phantom (16 cells, no collaborator) | bench drivers re-based on official clients; phantom dialect deleted or given a real client | OPEN |
| CT-02 | Axiom 2 anti-vacuity | CONFORMANT (courts) / PARTIAL (CSCT harness) | smalt shim courts flip (queue_capacity, ledger_blake3, ledger_chain, court_offset_restart+flipback); kafka-wire-pack verify.py 9/9 flips; arcus M1 SigV4→403 real wire mutation. Harness receipt hardcodes FAIL_CLOSED verdicts; no per-cell mutation | per-cell mutation attribution; receipt verdicts derived not hardcoded | OPEN |
| CT-03 | Axiom 3 quiet-host | PARTIAL | smalt `scripts/quiet_check.py:84-89` (load gate, typed REFUSE); arcus Andon-101 (`load1 > 0.15` exit 101) — but thermal/memory preflight lines are hardcoded prints, not samples; no thermal sampling, mem-headroom gate, pinning, or machine-readable ENV_REJECTED fleet-wide | real thermal+memheadroom samples, typed env-rejection status in result jsonl | OPEN |
| CT-04 | Axiom 4 economic derivation | PARTIAL | ROI gate executes (`cgap crates/csct` REQUIRED_ROI_X; arcus e2e ST-06 gates ≥350x). Fully burdened TCO missing on both sides: no labor/tooling/IOPS lines; SUT cost is a pinned constant | TCO calculator emitting C_inc/C_sut from rate cards + volumes | OPEN |

## Stages (§4)

| id | Stage | Verdict | Evidence receipt | Close condition | Status |
|---|---|---|---|---|---|
| CT-05 | ST-01 Warmer parity | PARTIAL | AOQ v3 golden Rust↔Elixir bidirectional (`aoq_v3_golden_bytes_fixture.rs:28`, smalt `test/data/aoq_v3_golden.hex`); wire-shm WIR0 3-language Rust↔Go↔BEAM (`wire_courts_golden.rs:205` + arcus `framed_test.go:308`); Arrow IPC Rust↔Elixir (`ipc_courts.rs:659-790`); kafka real-client parity (wp-kafka-wire-parity.md ALIVE). QUIC has no golden bytes; Arrow/AOQ lack Go legs | QUIC handshake/ALPN byte pin; Go legs for Arrow+AOQ | OPEN |
| CT-06 | ST-02 Reframe | REFUTED-claim / PARTIAL-capital | verdict:20 refutes 12.4 ns/record + 6.66x amplification (formula-generated); real analogs: frozen-duckdb 32x derivation, bench-s19 honest fail-closed lanes | measured amplification on the named surface | OPEN |
| CT-07 | ST-03 Rational Drowning | PARTIAL | cgap `drowning.rs` itemized cents ledger; arcus ST-03 asserts pinned constants (no line-item summing); smalt c9/cost3 measured Azure rate cards (compute+egress only, $0.00 measured egress honestly labeled SCENARIO) | calculator sums line items incl. burdens | OPEN |
| CT-08 | ST-04 Emotional | PARTIAL | real percentiles exist (`uds_transit_probe_test.go:123-135`, n=5000 min/p50/p99/p99.9/max; scvd/bench-s19 jsonl); incumbent 2,750ms is a hardcoded string; no burst injection anywhere; sequential probe only | 5–10x burst harness vs measured incumbent tail | OPEN |
| CT-09 | ST-05 New Way | PARTIAL | real 0-alloc courts (`cgap alloc_boundary.rs` budget(site,0,0); kill_stress alloc_delta={0,0}x100; CTQ-5 positive control); "0 B/op" universal claim REFUTED (measured 904.2 B/op, fence-witnessed); cache-utilization + persistence-latency gates MISSING; wire-shm ring has no alloc court | alloc court on wire-shm ring; cache metrics; persistence-latency bound | OPEN |
| CT-10 | ST-06 Solution | PARTIAL | receipts cite `cgap/reports/challenger_sales_combinatorial_receipt.json` which exists (cgap); BLAKE3/PQC attestation OVERCLAIMED x4 (verdict:21; 139.48ns hash-only, court asserts 1500ns, PQC label-only); combinatorial receipt uses SHA-256 not BLAKE3, hardcoded fallback SHA, `all_cells_admitted: True` unconditional | attestation actually exercised; receipt hash law fixed | OPEN |

## Anti-vacuity mutations (§5)

| id | Mutation | Verdict | Evidence receipt | Close condition | Status |
|---|---|---|---|---|---|
| CT-11 | M1 protocol/signature | PARTIAL | arcus M1 real wire 403 (`server.go:182-190`); smalt sigv4 vector court (falsifier leg is prose, 2 registered fail-open divergences KD-SIGV4-1/2); dialect guards GCP-401/Azure-CBS/Kafka-CRC unimplemented | sigv4 flip executed in-repo; dialect guards implemented | OPEN |
| CT-12 | M2 saturation | CONFORMANT | `queue_capacity_court.sh` capacity 4096→1 flip; cgap `ring_single_thread_roundtrip_and_capacity` (executed from arcus script — out-of-repo delegation noted) | in-repo saturation court in arcus | OPEN |
| CT-13 | M3 integrity | CONFORMANT | `ledger_blake3_court.sh`, `ledger_chain_court.sh`, `bk85_gate_court.sh`, aoq CERTS arm, cgap parity-flip court | — | CLOSED-WITH-EVIDENCE |
| CT-14 | M4 kill/replay | PARTIAL | `court_offset_restart.exs` real SIGKILL + flipback court; corrupt/truncated-journal-file replay leg MISSING; M4 executes in smalt via out-of-repo delegation | corrupt-journal replay leg | OPEN |

## Math invariants (§6)

| id | Requirement | Verdict | Evidence receipt | Close condition | Status |
|---|---|---|---|---|---|
| CT-15 | Little's Law W_ceiling | GAP | prose only in ADRs (W=10ms); no bench computes L/λ or fails on drift; arcus asserts it over fabricated numbers | measured residence-time gate | OPEN |
| CT-16 | ROI boundary ≥ K | PARTIAL | gate executes (≥350x) but over pinned constants; `min_memory_amplification_x: 4.53` receipt value contradicts the ≥6.66x contract with no check | gate over measured inputs | OPEN |

## Receipt (§7)

| id | Requirement | Verdict | Evidence receipt | Close condition | Status |
|---|---|---|---|---|---|
| CT-17 | qualification_status | PARTIAL | ADMITTED exists (`projection/admission.ex:13`, ggen v2 admission); no bench-provenance {ADMITTED,REFUSED} enum | bench receipt enum | OPEN |
| CT-18 | six-stage schema | GAP | no named six-stage bench schema; nearest closed pattern `bench/court_receipt.erl:15-17` ?FIELDS | schema module on that pattern | OPEN |
| CT-19 | mutation verdicts | GAP | no lawful producer; prior table was hardcoded (verdict doc) | derive from mutation-script exit codes | OPEN |
| CT-20 | hash | CONFORMANT | posh `blake3.go:272,289` TurnstileReceipt + chain links; BLAKE3_PIN cross-impl vectors; ggen.lock blake3 pins. Note: combinatorial harness uses hashlib.sha256 contrary to its own claim | harness switched to posh BLAKE3 | OPEN |
| CT-21 | signature | PARTIAL | ed25519 (`hw/signer.ex:28,34`), RS256 JWS (`vc_export.ex`); never bound to a benchmark receipt; PQC label-only | sign a CSCT receipt, verify path exercised | OPEN |
| CT-22 | provenance validation | GAP | `validate_receipt.py` checks schema not provenance (known vacuous-gate finding) | provenance check (subject SHA + re-run) | OPEN |

## Disqualification rules (§8)

| id | Requirement | Verdict | Evidence receipt | Close condition | Status |
|---|---|---|---|---|---|
| CT-23 | §8 mechanisms | GAP | no disqualification/demotion machinery anywhere; only unconditional ALIVE emitted; synthetic-driver / missing-mutation / unburdened-cost / contested-host / selective-stage rules all unenforced | typed DISQUALIFIED status + gate | OPEN |

## What is not claimed

- No cross-substrate interop run; ROI figures are model-derived, not metered.
- azure-eventhubs cells were never executed and have no collaborator.
- The 80-cell matrix's published latencies are formula-generated, not measured
  (witnessed by `csct-claim-verification-verdict.md:11` and X11).
- No RFC-0042 registration exists externally; this register treats the operator
  text as canonical, superseding the prior "§N resolves to nothing" reading.
