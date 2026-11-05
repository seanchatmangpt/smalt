# LANE-05 receipt — AOQ partitioned plane

Standing: PARTIAL_ALIVE

## Owned files

NEW:
- `lib/smalt/aoq/partitions.ex`
- `lib/smalt/aoq/partition_worker.ex` (defines `Smalt.Aoq.PartitionSink` default no-op sink at bottom)
- `lib/smalt/aoq/partition_sup.ex`
- `test/courts/court_aoq_partition_ordering.exs`
- `test/courts/court_aoq_partition_crash.exs`
- `test/courts/court_aoq_partition_wrap.exs`

APPEND-ONLY:
- `lib/smalt/aoq/supervisor.ex` — `:partitioned` config gate, default OFF; byte-identical boot when off. L1/L10 overlap disclosed: the offset-restart lane appended their persist children above my gated block; both blocks survive composition.

## Gates (ran this session, _build-lane5, asdf elixir 1.20.4-otp-29)

- `mix compile` — exit 0.
- `mix test test/courts/court_aoq_partition_wrap.exs test/courts/court_aoq_partition_ordering.exs test/courts/court_aoq_partition_crash.exs` — **Result: 4 passed** (0 failures, no skips).
- `mix test test/smalt/aoq` — 103/113; all 10 failures confined to two FOREIGN mid-flight files: `admission_test.exs` (L9 bisect-attribution shape) and `rdf_projector_court_test.exs` (L16 golden-vector/turtle-ordering convergence). Every pre-existing aoq suite (cursor/worker/supervisor/listener/tables/transport/session/frame/arrow) is green.

## Courts pin

- ordering: 4 producers x 2000 frames x 4 rings interleaved; per-producer per-ring
  seq strictly increasing in submission order (oracle `Cursor.seq_before?/2`, never
  `a < b`); per-ring uniqueness; 8000/8000 delivered through a real ETS sink;
  bounded polls, zero sleep.
- crash: kill p1 mid-stream; p0/p2 stay gapless (+1) and advancing through the
  kill window; p1 restarts under PartitionSup with a NEW pid, SAME registry
  cursor handle (`:atomics` ref unchanged), seq continues gapful-but-monotone;
  submits during the dead window return `{:ok, seq}` with dropped delivery.
- wrap (direct-call): `:atomics.put` near 2^64; `seq_next` is post-advance
  `add_get`; `seq_before?` half-space law pinned to cursor.ex `@half`/`@mod`;
  batch claim/release returns `in_flight` to 0.

## Cross-lane disclosures (both-receipt law)

1. `lib/smalt/aoq/worker.ex` — L9 admission attach applied by LANE-05 at L9's
   request (relayed by coordinator; L9 disclosed their side): `Worker.loop`
   accumulates a micro-batch (cap `Admission.batch_max/0` = 32) and dispatches
   `Smalt.Aoq.Admission.admit_batch/2`; tail batches drain on `:stop` and on the
   30 s GC heartbeat; the `NifHolder.parse` discard arm is gone (subsumed).
   L9 owns admission semantics + tests.
2. `lib/smalt/aoq/rdf_projector.ex` (L16 owns) — SLA unblocks during L16's
   rewrite churn while the file was fleet-blocking-broken: appended missing
   module `end` (x2), restored the truncated private-helpers section once from
   the pre-truncation snapshot, fixed `:"_:f"/:"_:s"` atom-concatenation bugs
   (String.to_atom forms). Most were superseded by L16's rewrites; surviving
   residue to re-check at integration: the two String.to_atom fixes in
   `triples_unsorted`.
3. `lib/smalt/messaging/kafka/supervisor.ex` (L6's append, L1 co-resident) —
   SLA unblock: L6's second JournalSink child used the default child_spec id,
   colliding with L1's JournalSink child id and refusing the whole app boot
   fleet-wide; minimal fix `id: Smalt.Aoq.LogSink` on the second child. L6
   supersedes.

## Design notes (pinned laws)

- `submit/2`: ONE persistent_term get, `Cursor.seq_next` (u64 wrap-safe), then
  `Process.whereis` + pid send. whereis-first is required: bare atom-name send
  raises badarg on an unregistered (dead) name; a dropped delivery with a
  consumed seq is the gapful-but-monotone crash law, never a caller crash.
- `PartitionWorker`: worker.ex isolation profile verbatim (`:link`,
  `message_queue_data: :off_heap`, `max_heap_size %{size: 2_097_152, kill:
  true, error_logger: true}`, 30 s GC heartbeat `# SLEEP-CLASS: POLL-STEP`);
  single claimant of its ring's head/tail; bounded 64-frame drain; parse via
  the `NifHolder` seam; `Cursor.drop` on refusal; batch release; `in_flight`
  returns to 0 per flush; sink seam `deliver(ring_id, seq, parsed)` so L6
  mounts storage via the `:sink` config key without editing these files.
- `Partitions`: cold-path GenServer; `{Partitions, :rings}` pt map
  ring_id -> {cursor, name}; ensure_ring idempotent (re-check under the call);
  drop_ring = terminate_child + `Cursor.reset` + pt erase; PartitionSup =
  DynamicSupervisor one_for_one keyed by ring_id; no gen_statem.
- Courts poll real observables (ETS sink table, `Cursor.in_flight`, whereis
  pids) via `SmaltTest.AssertEventually` — zero `Process.sleep`.
