# DMEDI Measure — v26.11.6

Standing: PARTIAL_ALIVE — measured rows are receipt-pinned; the rest are
UNMEASURED and stay UNMEASURED until a receipt lands.

## Baseline (measured this wave)

| Metric | Value | Gate / court | Receipt | Standing |
|---|---|---|---|---|
| SASL court | 16/16 pass | `test/internal/kafka_sasl_court_test.exs` | `receipts/kd191-kafka-sasl-lane10.md` | ALIVE |
| SASL shim non-vacuity | PASS, restore sha256 byte-exact | `scripts/shim_court/kafka_sasl_court.sh` | same | ALIVE |
| SASL negative-probe corpus | all legs PASS | `scripts/az1/kafka_sasl_negative_probe.py` | same | ALIVE |
| Partition courts (ordering/crash/wrap) | 4/4 | `test/courts/court_aoq_partition_{ordering,crash,wrap}.exs` | `receipts/lane5-aoq-partitioned-plane.md` | ALIVE |
| aoq suite | 103/113 (10 failures foreign mid-flight, bisected) | `mix test test/smalt/aoq` | same (as-of 2026-11-04) | ALIVE |
| Batch-SHACL admission court | 12 green | `test/smalt/aoq/admission_test.exs` | `receipts/lane9-aoq-admission.md` | ALIVE |
| Projector courts | 10/10 + sh:closed shim flip, restore sha-exact | `test/smalt/aoq/rdf_projector_court_test.exs` | `receipts/lane16-aoq-rdf-projector.md` | ALIVE |
| BLAKE3 gen-2 | 9/9 Elixir; Go ChainLink PASS; gate 14/14 refuse; shim PASS | `gates/ledger_chain_gate.py` | `receipts/lane11-blake3-chain-retarget.md` | ALIVE |
| QUIC NIF face tests | 16/16 | `test/smalt/aoq/quic_{certs,nif}_test.exs` + `test/courts/aoq_quic_roundtrip_court.exs` | `receipts/lane4-aoq-quic-nif.md` | PARTIAL_ALIVE (real-load arm BLOCKED, KD-192) |
| Kafka group court | layer-1 raw-TCP falsifiers + layer-3 restart leg | `test/internal/kafka_group_court_test.exs` | KD-190 row (canonical register) | UNVERIFIED (no receipt file) |
| Full `mix test` (wave-level) | not yet run at landing | — | landing receipt (Phase 2) | UNMEASURED at authoring time |

Wave-level `mix test` runs at landing (Phase 2 gate); this doc's last row
updates only from the landing receipt, never from memory.
