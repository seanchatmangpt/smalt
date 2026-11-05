# Lane WP — Kafka wire-parity repairs (KD-HC-1/2/3, matrix gap, downcv F3/F5)

Standing: ALIVE

Context: solo lane on the canonical checkout, 20-lane fleet running (~14 concurrent
mix compiles witnessed mid-pass; several waits stretched by compile contention).

## Per-defect fixes (all verified by court + real-client legs)

1. **Metadata matrix gap (KD-HC-1/L6)** — wire.ex `version_matrix` now caps
   Metadata at `{0, 3}` while Fetch caps at `{0, 3}` (transitive-consistency
   cap: the matrix must not advertise above the lowest transitively-capped
   family; advertising Metadata v4 makes real clients infer a (0,11,0) broker
   and send Fetch v4, crash-only kill, 1175 kills witnessed by L6). Chosen:
   cap Metadata {0,3}; serving Fetch v3 was already landed by L1 — both sides
   of the matrix now agree at v3.
   Evidence: `test/internal/kafka_wire_test.exs` "KD-HC-1: Metadata v4
   (unadvertised) is crash-only killed with telemetry" — typed kill
   `{:unsupported_version, 3, 4}`.

2. **KD-HC-1 named-topic echo + auto-create** — `conn.ex route(3, ...)`
   previously ignored the request body and served the topic census for every
   request; real clients (kafkajs/librdkafka) require the REQUESTED name
   present in the response. Now: null/empty topics array -> census; named
   array -> one block per requested topic (err 0 + full partition blocks when
   known; err 3 UNKNOWN_TOPIC_OR_PARTITION when unknown and auto-create is
   refused). v3+ reads the client's allow_auto_topic_creation byte; v0-v2
   requests default to the real-broker default (auto-create ON —
   auto.create.topics.enable default). Unknown + allowed -> `Log.ensure_topic/1`
   materializes `{topic, p} -> 0` next-counter entries.
   Evidence: kafkajs leg went from `KafkaJSProtocolError: This server does not
   host this topic-partition` to full green; librdkafka plaintext+SASL legs
   green.

3. **KD-HC-2 FindCoordinator v1** — `group_manager.ex handle_find_coordinator`
   now sends the KIP-113 v1 field order {throttle_time_ms i32, error_code,
   error_message (null), coordinator_id, host, port} = 27-byte body. Premise-rot
   disclosure: the vendored tmp/kafkalib `commit.py GroupCoordinatorResponse_v1`
   OMITS the throttle head (kafka-python fork divergence); KIP-113 +
   librdkafka are law — the 23-byte short form _UNDERFLOWed real librdkafka
   (HC receipt). kafka-python always sends FindCoordinator v0 (verified:
   `coordinator/base.py:727` uses `GroupCoordinatorRequest[0]`), so the
   vendored layer-2 group probe is unaffected.
   Evidence: `kafka_group_court_test.exs` "layer1: FindCoordinator v0/v1
   byte-exact" passes; librdkafka consumer group legs (plaintext + SASL)
   produce/consume/commit/resume green.

4. **KD-HC-3 ApiVersions v1/v2** — conn.ex `route(18, ver)` now serves
   version-correct payloads; the throttle_time_ms i32 for v1/v2 lands as a
   TAIL field AFTER the array (ApiVersions is the one API whose throttle
   lands last per the protocol guide/KIP-183). The prior HEAD placement made
   kafkajs parse throttle-as-error_code and read the array count from the
   error_code bytes (empty apiVersions -> "server does not support the
   requested API version" — witnessed with KAFKAJS_DEBUG). v0 stays bare;
   v3+ requests take the KIP-511 error-35 downgrade at dispatch.
   Evidence: kafkajs leg green end-to-end; wire court "KD-HC-3: ApiVersions
   v0/v1/v2 payload shapes are version-correct" pins the tail layout.

5. **downcv regression (F3/F5)** — `serve_batch` restored the pinned downcv
   F3 law: Fetch v2 serves stored magic-2 VERBATIM; v3 down-converts (KD-190
   posture, real Kafka serves magic-2 only from Fetch v4+); v0/v1 down-convert
   per KD-181. Court: `kafka_downcv_court_test.exs` F3 (v2 verbatim,
   byte-exact) + new **F5** pin (v3 down-converts to legacy v0 frames with
   valid IEEE CRC32; raw magic-2 bytes never appear on the v3 face).

6. **kd174 court premise rot (test-side)** — layer 2's hand-rolled Produce v3
   omitted the transactional_id null-string head (v3 request schema carries
   tid BEFORE acks; the parser correctly read acks as the tid length and
   killed the conn as malformed). Fixed the test to carry `<<-1::signed-16>>`.
   Layer 1 re-pinned: the probe sends one batch per value, so the byte-exact
   law is per-value (every value decodes back from SOME batch; every batch
   verifies + parses). Also `recv_all(sock, <<>>)` accumulator fix landed by
   the reconcile pass (LANE-01 disclosure).

## Test-side defects found by the courts (fixed during the pass)

- wire.ex moduledoc served-matrix table was stale (Fetch 0..0 / Metadata
  0..4) — synced to the actual matrix (Fetch 0..3, Metadata 0..3, group
  family, SaslAuthenticate 0..1, ApiVersions 0..2).
- My first ApiVersions tail-layout test used an illegal binary pattern
  (`body::binary` before a trailing field); rewritten with `binary_part/3`.
- LANE-01 SLA-unblock on my named-topic test (26 bytes per partition block,
  array count fields) — disclosed, kept.

## Lease disclosures (both-receipt law)

- `lib/smalt/messaging/kafka/group_manager.ex` — L1's file; I edited only
  `handle_find_coordinator` (KD-HC-2, coordinator-directed). L1's in-flight
  edits (matrix caps, ApiVersions head placement [superseded by my tail
  fix], serve_batch v2-verbatim restore, join debug Logger) landed around
  mine; final disk state is the merged result.
- `lib/smalt/messaging/kafka/log.ex` — OUTSIDE my lease (additive, disclosed):
  `list_topics/0` now unions `:smalt_kafka_next` keys, plus new
  `ensure_topic/1` for the KD-HC-1 auto-create face. Table pair is
  `:public` ETS (PartitionLog.ensure_tables), so the write is race-safe for
  this use. Consequence: `partition_known?/2` becomes true for
  auto-created topics (intended real-Kafka behavior). Fetch never
  auto-creates (EXPL-4 F4 fetch-error-3 leg still green).
- `lib/smalt/messaging/kafka/conn.ex` — shared with L1; my edits: route(3)
  rewrite (named echo + auto-create), route(18) throttle-tail fix, plus L1's
  serve_batch restore kept verbatim.

## Commands run (real outputs)

- `MIX_BUILD_ROOT=_build-laneWP mix test test/internal/kafka_wire_test.exs
  test/internal/kafka_downcv_court_test.exs test/internal/kafka_kd174_court_test.exs
  test/internal/kafka_group_court_test.exs` → **30 passed, 0 failures**
  (final run 83.9s; earlier full-suite run showed 1 cross-suite state leak in
  "two members join" which passes solo — pre-existing isolation leak, not a
  wire regression; final run passed all 30 in-suite).
- `SMALT_WF9_BOOTSTRAP=127.0.0.1:39796 node verification/ts/wf9-kafka.probe.mjs`
  → **PASS produce + PASS consume via group, WF9 rc=0** (kafkajs 2.2.4,
  KAFKAJS_DEBUG=1 evidence captured for the KD-HC-3 tail-layout finding).
- `hc-venv python verification/py/test_wf9_kafka.py` → **PASS plaintext
  produce/consume/commit/resume: 10 msgs; PASS sasl ... 10 msgs; WF9 rc=0**
  (confluent-kafka 2.16.1 / librdkafka 2.16.0; v9 + v11 sasl_required substrates).
- Earlier progressive evidence: first kafkajs attach run rc=1 "server does
  not support the requested API version" (head-throttle ApiVersions parse),
  then rc=1 "Producing to topic without metadata" (no named-topic echo),
  then rc=1 "does not host this topic-partition" (no auto-create) — each
  state diagnosed from wire debug and fixed.

## Standing

ALIVE — all five contract defects repaired, all four court suites green
(30/30), both real-client HC probe legs rc=0 (confluent plaintext + SASL,
kafkajs). Substrate beams for the probe blocks were killed after the runs
(no orphan listeners on 39790/39796/39816). KD-HC-1/2/3 witness receipts
point at this file; register rows not yet minted — coordinator mints rows
and runs `kd_flip.py --apply` (flip gate: witness receipt mtime > shim mtime
— satisfied as of this receipt's landing).
