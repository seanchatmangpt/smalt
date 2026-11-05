# Lane HC — real Kafka clients (confluent-kafka 2.16.1 / kafkajs 2.2.4) vs AZ-1 face

Standing: PARTIAL_ALIVE

Context: pair (v9 substrate + AoQ lane sharing the checkout; v10 boot blocked by the AoQ lane's shared-compile freeze on `lib/smalt/aoq/arrow/flatbuf.ex`)

## What landed

- `verification/ts/harness/substrate.ts` (additive): 7th port slot in `blockPorts` (39700+10n+6), `:kafka_port` put_env in the bootPrivate eval list, kafka-aware `waitHealthy`, asdf-mix spawn path (`SMALT_MIX` overridable), WO-32 cordon-aware health gate (arm/tls slots are NOT bound by a BEAM-only private boot — gating on them never converges; disclosed minimal unblock, bootPrivate only).
- `verification/ts/wf9-kafka.probe.mjs` (new): kafkajs leg. rc 0/1/2/3 contract. `SMALT_WF9_BOOTSTRAP=host:port` attach mode for when the shared compile is red. `KAFKAJS_DEBUG=1` captures wire-level evidence.
- `verification/py/test_wf9_kafka.py` (new, self-booting on `~/.asdf/shims/mix`): confluent-kafka legs on v9 (PLAINTEXT) and v11 (SASL, `sasl_required: true, sasl_mechanisms: [:plain]` put_env boot). rc 0/1/2/3.
- `verification/ts/package.json`: `kafkajs ^2.2.4` (additive); `verification/py/pyproject.toml`: `kafka` extra `confluent-kafka` (additive).

## Commands run (exit codes)

- Scratch venv: `pip install confluent-kafka` → 2.16.1 (librdkafka 2.16.0); `npm install kafkajs` → 2.2.4. Both registry-reachable.
- py leg run 4× during bring-up (2× blocked by foreign compile freeze, 1× sb_shared_key <32-byte floor refusal, then green boot): final real run:
  `python verification/py/test_wf9_kafka.py` → **rc=1**
  - PASS produce: 10 msgs delivered via flush-delivery-report (Produce v3, magic-2 RecordBatch).
  - FAIL consumer group: `KafkaError{code=_UNDERFLOW,val=-155,str="FindCoordinator response error: 127.0.0.1"}` — reproduced 3×.
  - SASL leg never ran client-side: v11 substrate boot died on the foreign `flatbuf.ex` compile error (recorded as substrate-fail, rc contract 2-class).
- ts leg, attach mode (`SMALT_WF9_BOOTSTRAP=127.0.0.1:39796`, KAFKAJS_DEBUG=1):
  `node verification/ts/wf9-kafka.probe.mjs` → **rc=1**
  - ApiVersions down-negotiation: v2/v1 answered "The version of API is not supported" + v0-shaped payload (face pins 18⇒{0,0}); kafkajs recovers at v0 (KIP-511 divergence noted, harmless).
  - Metadata v4 requests (named topic array `["wf9-ts-topic"]`) — **13 consecutive requests (correlationIds 3–15), zero responses**. librdkafka's null-topics Metadata works (produce delivered), so the suspect shape is the named-topic-array Metadata request parse. This is the finding; owners' lanes decide v4-vs-request-shape law.
  - End state: `KafkaJSNonRetriableError ← KafkaJSMetadataNotLoaded: Producing to topic without metadata`.
- `substrate-ctl down --block v9|v10|v11 --mode sweep` → all 7-slot faces closed.

## KD candidates (record only — server not fixed by this lane)

- **KD-HC-1 (Metadata v4 named-topic hang)**: kafkajs Metadata v4 with a non-null topics array never receives a response (13 unanswered requests). librdkafka (null topics) succeeds. Suspect: Metadata v4 request parse/route dead-ends on named-topic arrays.
- **KD-HC-2 (FindCoordinator v1 short response)**: librdkafka reads 23 bytes, expects 4 more (`_UNDERFLOW`), i.e. face's FindCoordinator v1 response is missing the 4-byte tail (throttle_time_ms) → librdkafka consumer-group path dead.
- **KD-HC-3 (ApiVersions v1/v2 tolerated-downgrade)**: face answers v1/v2 with UNSUPPORTED_VERSION + v0-shaped payload; kafkajs parses per requested version → garbage throttle_time_ms → negative client timeout (TimeoutNegativeWarning, -1793856360326 ms). Real brokers answer v1/v2 with a versioned error response.

## Not done / disclosures

- SASL leg never ran client-side: v11 boot blocked by the AoQ lane's in-flight `flatbuf.ex` compile breakage (3 distinct syntax/compile errors across 3 attempts, ~25 min, beyond the 10-min compile-freeze SLA). Not this lane's file; not fixed here.
- v10 substrate never booted green for the ts leg (same freeze). ts leg ran in attach mode on the v9 face — real wire, real client, but one shared face rather than its own block.
- `_build-laneHC` (probe compile probe) could not be removed — permission denied; coordinator should `just lane-clean` it.
- Pyright noise on substrate.ts (missing @types/node) is pre-existing environment; additive edits import-verified with node strip-types.
