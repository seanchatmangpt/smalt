# v26.11.6 Lane Ledger

Kafka-takeover wave (2026-11-04). Lane ids L59–L74 (continuing the
v26.11.5 L9–L58 sequence). Ownership is single-owner-per-file; straddling
lanes are disclosed in both receipts. Standing is read from the cited
receipt or on-disk court; rows without a receipts/ file are marked
receipt-pending / UNVERIFIED, never rounded up.

## smalt lanes

| Lane | Face | Owned files (new unless noted = modified) | Gates | Falsifier shape | Receipt | Standing |
|---|---|---|---|---|---|---|
| L59 | Kafka consumer-group family | `lib/smalt/messaging/kafka/group_manager.ex` (new); `conn.ex`/`wire.ex`/`supervisor.ex` (additive) | `test/internal/kafka_group_court_test.exs`; real-client probe `scripts/az1/kafka_group_probe.py` | real kafka-python-ng consumer cannot subscribe/commit/resume | KD-190 row in `../v26.10.14/KNOWN_DIVERGENCES.md` | OPEN (KD-190 close condition pending) |
| L60 | durable offsets | `lib/smalt/messaging/offset_journal.ex`, `lib/smalt/aoq/cursor_persist.ex` (new); `test/courts/court_offset_journal_test.exs`, `court_offset_restart.exs`, `scripts/shim_court/court_offset_restart_flipback.sh` | offset-journal court + restart court + flipback shim | offsets vanish across a GroupManager restart | receipt-pending at landing (courts on disk) | UNVERIFIED |
| L64 | dual-wire PartitionLog | `lib/smalt/messaging/partition_log.ex` (new), `lib/smalt/messaging/kafka/log.ex` (additive); `test/internal/aoq_log_court_test.exs`, `scripts/shim_court/kafka_vs_aoq_court.sh`, `bench/kafka_vs_aoq_court.erl` | `aoq_log_court` + `kafka_vs_aoq` shim court | a Kafka-face produce diverges from the AoQ ring view of the same partition | receipt-pending | UNVERIFIED |
| L61/L62 | QUIC server/client | `lib/smalt/aoq/quic/{nif,quic,certs}.ex`, `scripts/build_aoq_nif.sh`, `scripts/gen_dev_cert.sh` (rider), `test/courts/aoq_quic_roundtrip_court.exs`, `test/smalt/aoq/quic_{certs,nif}_test.exs` | 16/16 tests + roundtrip court (server-role arm BLOCKED on cgap L3) | roundtrip loopback fails; wrong-CA admits | `receipts/lane4-aoq-quic-nif.md` | PARTIAL_ALIVE |
| L63 | partition rings | `lib/smalt/aoq/{partitions,partition_worker,partition_sup}.ex` (new); `test/courts/court_aoq_partition_{ordering,crash,wrap}.exs` | 4/4 partition courts + 103/113 aoq suite (10 failures foreign mid-flight, bisected) | per-producer per-ring seq non-monotone; crash-window non-monotone; u64 wrap mishandled | `receipts/lane5-aoq-partitioned-plane.md` | PARTIAL_ALIVE |
| L65 | flatbuffer IPC | `lib/smalt/aoq/arrow/flatbuf.ex` (new) | lakehouse IPC court (`test/courts/court_lakehouse_ipc_ct_test.exs`) | IPC frame diverges from the Arrow flatbuffer law | receipt-pending | UNVERIFIED |
| L66 | bench court | `bench/bench_aq_boundary_alloc.erl`, `bench/kafka_vs_aoq_court.erl` (new) | bench lanes write their own result jsonl | bench emits no receipt | receipt-pending | UNVERIFIED |
| L67 | batch SHACL admission | `lib/smalt/aoq/admission.ex` (new), `lib/smalt/graphlaw_ex/shacl_admission.ex` (modified), `test/smalt/aoq/admission_test.exs`, `test/fixtures/aoq_admission/`, `justfile.d/08-publish-dry.just` + `scripts/publish_dry_rider.sh` (rider) | 12-court admission suite; publish-dry WO-10 regression rider | mutation flip fails to turn the court red | `receipts/lane9-aoq-admission.md` | ALIVE |
| L68 | SASL face (KD-191) | `lib/smalt/messaging/kafka/sasl.ex` (new), `wire.ex`/`conn.ex` (additive), `scripts/az1/kafka_sasl_{,negative_}probe.py`, `test/internal/kafka_sasl_court_test.exs`, `scripts/shim_court/kafka_sasl_court.sh` | 16/16 court; shim court PASS (byte-exact restore) | unadvertised mechanism → 33+kill flips nothing | `receipts/kd191-kafka-sasl-lane10.md` | PARTIAL_ALIVE |
| L69 | BLAKE3 chain retarget gen-2 | `lib/smalt/security/ledger_writer.ex` (mod), `gates/ledger_chain_gate.py` (mod), `gates/blake3_ref.py` (new), `verification/chain_link_vectors.json` (new), `posh/internal/receipt/chain_link_test.go` (new) | 9/9 Elixir + Go ChainLink PASS + gate verdict=PASS (14/14 refuse) + shim PASS | hex-fold vs raw32 fold divergence asserted in all 3 languages | `receipts/lane11-blake3-chain-retarget.md` | ALIVE |
| L70 | lakehouse mount (Erlang) | `src/smalt_lakehouse_mount.erl` (mod), `test/courts/court_lakehouse_ipc_{SUITE.erl,ct_test.exs}` | lakehouse IPC CT court | mount face diverges from the AoQ seal law | receipt-pending | UNVERIFIED |
| L71 | PQC admission (NifHolder PQC leg) | `test/smalt/aoq/nif_holder_pqc_test.exs` (new) | staged-NIF PQC leg refuses without a real dylib | court admits with a fake dylib | receipt-pending | UNVERIFIED |
| L72 | arcus adapters | arcus `internal/{ingress,egress,messaging}/` | per-dialect roundtrip court (arcus-side) | adapter diverges from the AoQ membrane law | arcus `docs/jira/v26.11.5/receipts/l14-kafka-adapter.md` | PARTIAL_ALIVE |
| L73 | kafka-wire-pack | ggen-marketplace `packs/kafka-wire-pack/` | pack qualification (marketplace gates) | pack renders a face smalt's `wire.ex` does not serve | receipt-pending | UNVERIFIED |
| L74 | RDF projector | `lib/smalt/aoq/schema_bindings.ex`, `lib/smalt/aoq/rdf_projector.ex` (new); `test/smalt/aoq/rdf_projector_court_test.exs`, `test/integration/graphlaw_canonical_shapes_court_test.exs` | 10-court projector file green + sh:closed shim court flips court 10 RED, restore sha-exact | remove `sh:closed` → court 10 RED (executed) | `receipts/lane16-aoq-rdf-projector.md` | ALIVE |

## Charter-id ↔ receipt-number mapping

Receipts kept their original lane numbering (4/5/9/10/11/16); this ledger
is the mapping: L61/L62→receipt lane 4, L63→lane 5, L67→lane 9,
L68→lane 10 (KD-191), L69→lane 11, L74→lane 16.

## Exclusions (never committed)

`_build*`, `tmp/`, `*.beam`, `erl_crash.dump`, `substrate.log`,
`priv/aoq/aq_beam_nif.*` (dylib, gitignored by this wave's .gitignore
rider), `priv/data/` (runtime offset-journal artifacts — ignored rider
added at landing).

## Open faces

- QUIC server role (cgap server table + staged dylib rebuild): L61
  server-role court arm BLOCKED on cgap L3 — see
  `receipts/lane4-aoq-quic-nif.md` + KD-192.
- KD-190 close condition (journaled group offsets): L60 is the surface;
  KD-190 row stays OPEN until the restart court is receipted.
- Real-client census (librdkafka / Java) — wave +1 hardening seed.
