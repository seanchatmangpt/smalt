# Receipt: ERL-3 Kafka/Wormhole/Proposer reference modules + court

**Standing:** **ALIVE**
Context: solo

## Subject

Operator-supplied Erlang reference modules landed at /Users/sac/smalt
(branch main) and courted. Computed via `erlc_paths: ["...", "src"]`
(mix.exs:15), so the modules compile under the normal mix build.

- `src/smalt_eventhubs_kafka.erl` — Kafka wire frame handler.
  Produce (API_KEY=0) layout exactly per operator contract:
  `[Size:32|ApiKey:16|ApiVer:16|CorrId:32|ClientLen:16|ClientId|TopicLen:16|Topic|Partition:32|BatchLen:32|RecordBatch]`;
  sieve = Kafka RecordBatch v2 magic-byte (offset 16) check; pass →
  monotonic-offset store put_cas + journal append → ProduceResponse
  `[CorrId:32|TopicLen:16|Topic|Partition:32|ErrorCode:16|Offset:64(signed)]`;
  sieve refusal → EC=1, Offset=-1, durable andon journal frame, no
  offset minted. Fetch (API_KEY=1, FetchOffset:64) → contiguous records
  `[Offset:64 Len:32 Payload]*` or empty Count=0. Malformed frames →
  `malformed_kafka_wire_frame`; unknown api key → `{unsupported_api_key, N}`.
  CloudEvents v1.0 binary (op 16#CE): handle_cloudevent/1 +
  publish_cloudevent/3 → put_cas + journal + merkle receipt (32-byte).
- `src/smalt_wormhole.erl` — `#wormhole{t_ns, seal_ref, universe_hash,
  quad_count, snapshot_bin}` in an ordered_set heir'd ETS
  (`smalt_store_heir:get_heir_pid()`, `{keypos, 2}` so the key is the
  monotonic-ns anchor time; Id scoping via `seal_ref {Id, T_ns}`).
  freeze_universe/2 = Algorithm 1 (sha256 content-address + insert +
  add/drop delta journal frames); time_travel/2 = Algorithm 2
  (nearest-prior via ets:prev scoped by seal_ref, sha256 integrity +
  seal-identity check per record → `wormhole_tamper_detected`,
  empty prior chain → `no_prior_wormhole_anchor`, then O(k) residual
  delta replay (k = freezes crossed; missing journaled delta at a
  crossed freeze = tamper evidence)); optimal_spacing_ms/3 = Theorem 9.4
  `round(sqrt(C_freeze/C_replay * T_total))`.
- `src/smalt_proposer_gate.erl` — evaluate_proposal/4 (Op 1 SHACL-class
  validation fun, then Op 2 N3-class sieve fun; admit → `{admitted, ETag,
  Receipt}` via store put_cas + journal + merkle receipt; refusal →
  `{andon_refusal, Reason, -1.0}` with the refusal itself journaled and
  the proposal NOT stored); aggregate_federated_shards/3 (L2 clip each
  shard to MaxNorm, average, charge 1 from the privacy budget;
  `empty_federated_shards` / `privacy_budget_exhausted` typed refusals)
  + clip_vector/2, average_vectors/1.

## Adapters (ERL-1 not landed)

`smalt_arm_router.erl` (ERL-1) is not on disk and its named deps
`smalt_journal_sink:append_frame/5` / `smalt_merkle:mint_single_receipt/3`
do not exist, so per dispatch the same thin-adapter style as
`smalt_journal_sink_compat` was used:

- `src/smalt_arm_adapters.erl` — `append_frame/5` (append-only journal
  over STORE-4: monotone unique_integer seq, keys `{journal, Stream,
  Seq}` distributed across the 16 partition tables; `read_frames/2`
  merges all 16 tables in Seq order), `mint_single_receipt/3` (deterministic
  sha256 merkle root over {Stream, Frame, ETag} triples), `current_etag/1`.
- `src/smalt_store_heir.erl` — additive export `get_heir_pid/0`
  (idempotent, plain spawn + race-safe register). Small additive edit to
  the landed STORE-4 module, disclosed here per lane discipline.

## Court transcript (verbatim)

    $ erlc -o ebin/ src/smalt_eventhubs_kafka.erl src/smalt_wormhole.erl src/smalt_proposer_gate.erl src/smalt_arm_adapters.erl src/smalt_merkle.erl src/smalt_store.erl src/smalt_store_sup.erl src/smalt_store_heir.erl src/smalt_store_partition.erl test/courts/court_kafka_wormhole_proposer_SUITE.erl
    ERLC_CLEAN   (exit 0, zero warnings on the five lane files)

    $ erl -pa ebin/ -noshell -s court_kafka_wormhole_proposer_SUITE run_court
    == ERL-3 kafka/wormhole/proposer court ==
    PASS 1 kafka produce->fetch byte-exact round-trip
    PASS 2 kafka sieve refusal -> produce EC=1 + durable andon
    PASS 3 kafka malformed frames -> malformed_kafka_wire_frame
    PASS 4 cloudevent v1.0 binary -> monotonic offset + merkle receipt
    PASS 5 wormhole freeze->travel + Theorem 9.4 spacing math
    PASS 6 wormhole tamper + no-anchor refusals
    PASS 7 proposer Op1 SHACL + Op2 sieve admit / andon refusals
    PASS 8 federated clip-to-MaxNorm + average + refusals
    COURT RESULT: 8/8 PASS
    exit: 0

## Command exits

- erlc compile (9 files + court): exit 0, zero warnings on lane files
- court run 1: exit 0 (8/8 PASS)
- court stability rerun (independent erl process): exit 0 (8/8 PASS)
- dynamic-atom scan over the four new modules: only match is the module
  doc comment — zero dynamic atoms on wire paths

## Falsifiers exercised

- produce→fetch round-trip byte-exact; two produces land offsets 0,1;
  fetch from 0 returns both records in order
- sieve refusal (RecordBatch magic 9): EC=1, Offset=-1, fetch sees no
  records, andon frame durable in journal
- truncated envelope, short body, unsupported api key → typed refusals
- cloudevents: 32-byte receipts differ across payloads; offsets 0,1,2
  monotonic; bad version/magic → `malformed_cloudevent_frame`
- wormhole: between-freezes target → Q0 replayed 0; post-final target →
  Q1 replayed 0; wh_court2 middle anchor Q1 then post-drop Q0; tampered
  snapshot_bin (real ets:update_element mutation) → `wormhole_tamper_detected`;
  never-frozen Id → `no_prior_wormhole_anchor`; optimal_spacing_ms
  (1,4,100)=5, (4,1,25)=10, (1,1,0)=0
- proposer: admit stores {0, Proposal} + journals + receipts; both andon
  paths return -1.0 with typed reasons and do NOT store the proposal
- federated: [[3,4],[6,8]] → [3.0,4.0] with budget 10→9; average case;
  empty + zero-budget typed refusals; clip_vector boundary cases

## Standing

ALIVE: exact subject courted twice, exit 0 both runs, erlc clean, zero
dynamic atoms on wire paths. ERL-1 integration pending (adapters bridge
the named seams). No KD register rows minted. Not committed (per
dispatch).