# L59 — paired Kafka-vs-AoQ throughput court + AoQ boundary alloc repair

Standing: UNVERIFIED

Context: solo

Machine: Apple M3 Max 16c/48GB, elixir 1.20.4 / otp 29.1.2 / darwin 26.2,
fleet-loaded (concurrent lane beams were running during measurement —
wall-clock numbers carry that load).

## Diff

- `bench/kafka_vs_aoq_court.erl` (new) — paired ALTERNATING rounds court:
  KAF round r then AOQ round r, 7 measured rounds + 1 discarded warmup +
  10k burn-in ops/leg, min-of-N headline. KAF leg = raw `:gen_tcp` Produce
  v3 (v2-shaped body, no transactional_id — the served parser reads
  acks-first; KD-174 posture), batch per op via
  `Smalt.Messaging.Kafka.Records.encode_batch/1` (NO Python in the
  measured path — AR-BENCH-03), completion = ack parsed (error 0 +
  base_offset >= 0). AOQ leg = `:socket.sendmsg` of the
  `Smalt.Aoq.Frame.encode_frame/2` iolist (flattened for `sendmsg` — the
  OTP socket API requires binary iov entries) to the UDP listener;
  completion = pool seq atomic >= target (L46 observable). Secondary
  fire-and-forget Kafka row (send-only) pairs the drain face (PAIR-MODE
  disclosure). Alloc probes: tprof call_memory scoped
  `processes => [self()]` (caller-side alloc only; unscoped tprof traces
  the whole node and slows the loop orders of magnitude — witnessed).
  Fences: R = aoq_drain/kaf_acked in [2.0, 200] both directions
  fail-closed; caller-side alloc <= 128 B/op per leg; leg bring-up smoke
  (both faces bind + one op each, abort nonzero otherwise); calibration
  first run unfenced-informational.
- `bench/bench_aq_boundary_alloc.erl` (repair, C7 dead-lane inventory) —
  the tprof 4-tuple `{M,F,A,[{Pid,Calls,Words}]}` pattern in
  `profile_words/1` was ALREADY CORRECT (shape verified empirically on
  OTP 29 this session); the real defects were in the fence architecture:
  (1) size-invariance was evaluated PER-ROW (absolute words > 4) instead
  of the contract's cross-size `words(4080B) - words(1B) <= 4` — encode
  legitimately allocates a 9-word constant, split 24–26 words (sub-binary
  match-alloc), so per-row application red-fenced lawful zero-payload-
  scaling ops; (2) the ratio twins allocated a word-CONSTANT (refc binary
  copies allocate a constant ProcBin header regardless of size), making
  the ratio size-blind — replaced with word-proportional twins
  (`lists:seq(1,S)` ≈ 2 words/byte + payload copy); (3) S=1 ratio rows
  are word-floor-limited (no payload-proportional twin can outrun the
  op's constant at 1B) — typed PASS+floor_ratio, disclosed, claim carried
  by the cross-size fence; (4) band negotiation: calibration widens the
  0.05 authored band to the next 0.01-grid value measured-then-fenced
  (measured max 0.05 exactly at split@256 — landed within the authored
  band, no widening fired this session). Falsifier shims are now
  word-proportional and flip BOTH fences at every size (SHIM COURT: all
  rows red). `erlc` compile command in the file header updated.
- `lib/smalt/messaging/kafka/records.ex` — MINIMAL UNBLOCK fix (NOT my
  owned file; compile-freeze-class, disclosed in this receipt): the
  varint accumulator was prepended per group then returned head-first,
  so any varint >= 128 encoded BYTE-REVERSED (263 -> `<<4, 0x8E>>` instead
  of `<<0x8E, 0x04>>`); every record whose length/varint needed >1 byte
  failed the broker's own parse_records with
  `{:error, :record_count_mismatch}` — the encode face produced batches
  the broker refuses. Witnessed this session: encode→verify :ok but
  parse :error on a 326B batch; a raw-TCP produce probe answered error 2
  CORRUPT_MESSAGE acks. One-line fix (reverse the accumulated groups
  before flattening); roundtrip + wire probe green after. KD-197 minted
  in `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md`.
- `scripts/shim_court/kafka_vs_aoq_court.sh` (new) — SHIM-COURT: BASELINE
  sha256 -> BEFORE (alloc fence holds unshimmed) -> SHIM (per-op
  `binary:copy(<<0:768>>)` perturbation armed in BOTH legs' measured op
  paths, `%% SHIM-COURT` marker mandatory) -> AFTER (fence MUST flip,
  else VACUOUS GATE exit 1) -> RESTORE (sha256 byte-exact, fail-closed).
- `scripts/bench/aq_throughput.sh` — NOT modified: judged that the L46
  throughput lane does not need the paired Kafka leg; the paired court
  is standalone (`bench/kafka_vs_aoq_court.erl`). No fork, no edit.
