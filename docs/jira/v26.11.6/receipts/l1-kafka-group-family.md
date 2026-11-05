# L1 — Kafka serve-group family (KD-190) + SLA surface fixes

Standing: PASS

Files (lane-owned, all edited this session):
- `lib/smalt/messaging/kafka/group_manager.ex` (new) — serialized GenServer
  coordinator: 2 ETS tables (:smalt_kafka_groups, :smalt_kafka_group_offsets),
  Empty→PreparingRebalance→CompletingRebalance→Stable, generation bumps,
  roundrobin + range assignors, parked JoinGroup/follower-SyncGroup replies,
  typed refusals (protocol_type != "consumer" → 23, cooperative-sticky → 23,
  session_timeout <= 0 → 26; static membership = crash-only version cap,
  JoinGroup v5+ out-of-matrix), send_after sweeper (SLEEP-CLASS: SCHEDULING).
- `lib/smalt/messaging/kafka/wire.ex` — group-family keys verified from the
  vendored protocol module (8,9,10,11,12,13,14), caps strictly below the
  KIP-482 flexible thresholds and matched to the vendored class lists
  (LeaveGroup 0..1: v2 does not exist in the vendored module — plan's 0..2
  was premise rot); Metadata capped {0,3} (KD-HC-1/L6: advertising v4 makes
  clients infer (0,11,0) and send Fetch v4 → crash-only kill); Fetch {0,3}
  (vendored client sends v3 at the (0,10,1) posture without
  down-negotiation); ApiVersions {0,2} (KD-HC-3).
- `lib/smalt/messaging/kafka/conn.ex` — group-family routes + public
  send_response (parked-reply delivery), Produce v3 transactional_id parse,
  take_partitions typed-kill (was uncaught MatchError conn crash), Fetch v3
  parse (top-level max_bytes between min_bytes and topics), serve_batch v3
  down-conversion with v2 VERBATIM restored (pinned downcv F3 law) and
  v0/v1 per KD-181, Metadata controller_id = -1 (HC court pin),
  SLA-UNBLOCK: restored the missing `dispatch(req, %{phase: :open})`
  clause L10's SASL rewrite dropped (every non-SASL frame was killed
  :malformed_request_header; disclosed for L10's receipt).
- `lib/smalt/messaging/kafka/supervisor.ex` — GroupManager child appended
  (disclosed overlap with L6 stage-1; L6 later added AoQ + OffsetJournal
  children to the same file).
- `test/internal/kafka_group_court_test.exs` (new) — layer-1 raw-TCP
  falsifiers (JoinGroup v5 crash-only + telemetry reason; in-band 23/23/26
  refusals; two-member generation dance; parked follower sync; heartbeat
  22/25; sweeper eviction; commit/fetch offsets), layer-2 real
  kafka-python-ng probe (commit/resume/disjoint-roundrobin/LeaveGroup),
  layer-3 restart-persistence witness (OffsetJournal journaled offsets
  survive a GroupManager restart — KD-190 close condition met this session
  by the coordinated OffsetJournal lane; flip remains kd_flip-gated).
- `scripts/az1/kafka_group_probe.py` (new) — real client probe, legs
  A/B/C, os._exit honesty (kafka-python background threads cannot join at
  interpreter shutdown), threaded leg C, no fixed sleeps (bounded polls).
- KD-190 row minted in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.

Conflict flags / SLA unblocks (disclosed in BOTH receipts):
- L10: their mid-flight conn.ex SASL rewrite dropped the :open dispatch
  clause (fleet-blocking); I restored it minimally; L10 supersedes.
- L6: I appended my GroupManager child to supervisor.ex; L6's stage-1 +
  AoQ/OffsetJournal children coexist; no edits to their blocks.
- kafka_wire_test.exs HC-1 test: authored per-partition block arithmetic
  was 22B (omitted the two array count fields); protocol block is 26B —
  fixed in place with disclosure; HC lane supersedes.
- kd174 court: fixed pre-existing `recv_all(sock, 0)` int-acc crash +
  added the v3 produce-response throttle tail to the decode pattern
  (this leg had never executed successfully before the fix).
- GroupManager heartbeat: any member request refreshes session liveness
  (incl. 27 REBALANCE_IN_PROGRESS answers) — witnessed: kafka-python
  members were evicted mid-rebalance otherwise.

Real errors corrected from the plan (premise rot, re-verified from the
vendored client):
- api keys: OffsetCommit=8 OffsetFetch=9 FindCoordinator=10 JoinGroup=11
  Heartbeat=12 LeaveGroup=13 SyncGroup=14.
- REBALANCE_IN_PROGRESS = 27 (not the plan's "16").
- OffsetFetch response metadata is an empty string, not null; FindCoordinator
  v1 carries a throttle head (librdkafka _UNDERFLOW witness, KD-HC-2).

Commands + exits:
- `MIX_BUILD_ROOT=_build-lane1 MIX_ENV=test mix compile` → exit 0
  ("Generated smalt app").
- `MIX_BUILD_ROOT=_build-lane1 MIX_ENV=test mix test
  test/internal/kafka_group_court_test.exs test/internal/kafka_wire_test.exs
  test/internal/kafka_kd174_court_test.exs
  test/internal/kafka_downcv_court_test.exs`
  → exit 0, `Result: 30 passed` (run twice consecutively, both 30/30;
  includes the KD-190 court 11 legs, wire court, kd174 court, downcv court).

Standing vocabulary: PASS (11/11 KD-190 legs + 30/30 four-court run,
observed this session, exact commands above).

KD-190 standing: OPEN — offsets persistence landed via OffsetJournal
(coordinated lane), layer-3 court leg witnesses the close condition;
flip to CLOSED via scripts/kd_flip.py --apply once this receipt postdates
the shims (flip is coordinator-owned).

## Cross-lane disclosure

- `lib/smalt/messaging/kafka/log.ex` — additive edit outside this lane's
  lease, disclosed by the WP lane in
  `docs/jira/v26.11.6/receipts/wp-kafka-wire-parity.md` ("OUTSIDE my lease
  (additive, disclosed)": `list_topics/0` unions `:smalt_kafka_next` keys,
  new `ensure_topic/1` for the KD-HC-1 auto-create face). WP is the
  disclosing side; this receipt's header previously claimed both-receipt
  coverage without naming log.ex — the counterparty line is completed
  here.
