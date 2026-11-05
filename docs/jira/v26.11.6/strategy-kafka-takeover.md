# Strategy — Kafka-Takeover Tax Table (measured-only)

Standing: PARTIAL_ALIVE — every row is receipt-pinned or UNMEASURED.
"Wire-reachable at protocol version X" is the only lawful compat claim;
"Kafka-compatible" is banned from this doc.

## Tax table

| Surface | Tax (what the takeover pays) | Measured value | Receipt pin |
|---|---|---|---|
| Kafka wire face (produce/fetch) | face serves real clients at the api-key matrix in `wire.ex` | UNMEASURED — no wave-level throughput/latency receipt yet | `test/internal/kafka_kd174_court_test.exs` (court, no receipt file) — UNVERIFIED |
| Consumer groups (KD-190) | in-memory group offsets — restart drops them until L60 receipts | divergence registered, not measured | KD-190 row, `../v26.10.14/KNOWN_DIVERGENCES.md` (OPEN) |
| SASL PLAINTEXT (KD-191) | PLAIN only, SASL_PLAINTEXT only; no SASL_SSL | 16/16 court + negative corpus + shim PASS | `receipts/kd191-kafka-sasl-lane10.md` |
| SASL_SSL / TLS on the Kafka face | not served; TLS face is a registered deferral (KD-194) | UNMEASURED | `KNOWN_DIVERGENCES.md` KD-194 |
| QUIC client role | NIF client face over cgap-beam dylib; loader/certs courts green | 16/16 tests; roundtrip arm BLOCKED | `receipts/lane4-aoq-quic-nif.md` |
| QUIC server role | not served in the staged dylib; cgap rebuild red mid-wave | UNMEASURED | KD-192 + lane4 receipt BLOCKED section |
| Dual-wire PartitionLog | one log serves Kafka face + AoQ plane; no measured divergence | UNMEASURED | `test/internal/aoq_log_court_test.exs` (no receipt file) — UNVERIFIED |
| Durable offsets (L60) | restart-survival court + flipback shim on disk, no receipt | UNMEASURED | `test/courts/court_offset_restart.exs` — UNVERIFIED |
| Batch SHACL (L67) | O(batches) admission over micro-batches, replay ledger TTL | 12-court suite green; no latency receipt | `receipts/lane9-aoq-admission.md` |
| RDF projector (L74) | drain-boundary projection on the real pinned wasm engine | 10/10 courts + shim flip | `receipts/lane16-aoq-rdf-projector.md` |
| BLAKE3 gen-2 link | link retarget, gen-1 replay verifies forever | 9/9 Elixir + Go PASS + gate 14/14 + shim PASS | `receipts/lane11-blake3-chain-retarget.md` |
| Lakehouse IPC mount (L70) | Erlang mount + CT court, no perf claim | UNMEASURED | `test/courts/court_lakehouse_ipc_ct_test.exs` — UNVERIFIED |
| PQC admission leg (L71) | NifHolder PQC leg refuses without a real dylib; cgap L14 pqc_seal composite seal/open is the upstream seal surface | UNMEASURED in smalt | cgap L14 receipt (PARTIAL_ALIVE, v26.11.5 wave) |
| arcus adapters (L72) | per-dialect roundtrip through one membrane boundary | UNMEASURED | arcus `docs/jira/v26.11.5/receipts/l14-kafka-adapter.md` — PARTIAL_ALIVE |
| GCP/Kinesis/SQS faces | not built; S15/S16/S17 registered seeds | UNMEASURED | `../v26.11.5/strata-backlog.md` S15–S17 |
| 55,411 trips/sec (arcus UDS) | number cited from commit message, never receipt-pinned | UNVERIFIED | `../v26.11.5/strata-backlog.md` S5 |

Every UNMEASURED row admits only when a receipt lands against the exact
surface; a calendar date never admits.
