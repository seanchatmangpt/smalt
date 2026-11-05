# DMEDI Define — v26.11.6 Kafka-Takeover Wave

Standing: PARTIAL_ALIVE — Define authored 2026-11-04 at wave finale from
on-disk receipts and courts; nothing is cited from memory without an
on-disk citation.

## Problem statement

The smalt AoQ plane (v26.11.5) landed without wire faces a real Kafka
client can reach. The wave's job: give the AoQ native plane wire-reachable
faces (Kafka produce/fetch/groups/SASL), durable offsets, a dual-wire
partition log, flatbuffer IPC, a lakehouse mount, and PQC/BLAKE3 admission
hardening — without forking the native log.

## Scope (in / out)

In scope (this wave):
- Kafka wire face: group family (L59), durable offsets (L60), dual-wire
  PartitionLog (L64), SASL PLAINTEXT (L68, KD-191).
- AoQ plane hardening: partition rings (L63), batch SHACL admission
  (L67), RDF projector (L74), BLAKE3 gen-2 chain (L69), QUIC NIF client
  face (L61/L62), lakehouse IPC mount (L65/L70), PQC NifHolder leg
  (L71).
- Fleet surfaces: arcus adapters (L72), kafka-wire-pack (L73).

Out of scope (explicit exclusions):
- Transactions, exactly-once, compaction, KIP-482 (except the compact
  helpers L68 needed for SaslAuthenticate v1), replication fabric
  (S21), io_uring (S20), GCP/Kinesis/SQS faces (S15/S17 faces deferred;
  S16 Kinesis REST — wave +2).
- "Kafka-compatible" claims — banned; the lawful claim is
  "wire-reachable at the protocol version the face serves".
- QUIC server role — BLOCKED on cgap L3 (KD-192), scoped to wave +1.

## Customers and Y=f(x)

- Customers: real Kafka clients (kafka-python-ng probes are the standing
  in-fleet surrogate), the AoQ drain boundary (L67/L74), the smalt
  receipt ledger (L69), the lakehouse SQL-over-log path (S19).
- Y (primary metric): a real-client produce/consume loop through the
  Kafka face that the AoQ native log absorbs without a per-face fork.
  Current standing: layer-1 raw-TCP courts + real-client probes green
  in-fleet; wave +1 adds librdkafka/Java census legs.

## Charter-to-lane mapping

Charter ids L61/L62→receipt lane 4; L63→lane 5; L67→lane 9; L68→lane 10
(KD-191); L69→lane 11; L74→lane 16. Full table: `_LANES.md`.

## Voice of the customer (measured-only)

- Auth that authenticates: 16/16 SASL court + negative-probe corpus PASS,
  shim PASS (`receipts/kd191-kafka-sasl-lane10.md`).
- Offsets that survive restart: restart court + flipback shim on disk;
  receipt-pending; KD-190 row OPEN.
- Produce/consume loops that don't crash: kafka_group court layer-1
  raw-TCP falsifiers + layer-3 restart leg; the produce-face KD-174
  court (`test/internal/kafka_kd174_court_test.exs`, on disk) is the
  falsifier for the bare magic-2 batch support the SASL vendored probe
  leg needed.
