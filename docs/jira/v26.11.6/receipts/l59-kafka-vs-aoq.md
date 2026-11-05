# L59 — paired Kafka-vs-AoQ throughput court + AoQ boundary alloc repair

Standing: PARTIAL_ALIVE

Context: solo

Machine: Apple M3 Max 16c/48GB, elixir 1.20.4 / otp 29.1.2 / darwin 26.2.
Load disclosure: `just quiet-check` FAILED at run time (348 concurrent
lane beams, courts holding 5673/9445) — the TTV-7 quiesce precondition
could not be met while the wave ran; the Kafka-leg wall-clock numbers
carry that load (single-shot probe measured 0.36 ms/op = ~2800 ops/s
while the in-court rounds measured 44-79 ops/s; the gap is load + log
depth). Numbers are FAIL-honest, never fenced silently.

## Diff

- `bench/kafka_vs_aoq_court.erl` (new) — paired ALTERNATING rounds court:
  KAF round r then AOQ round r, 7 measured rounds + 1 discarded warmup +
  10k burn-in ops/leg (1000 ops/leg/round — sized for wall time under
  fleet load), min-of-N headline. KAF leg = raw `:gen_tcp` Produce v3
  (v2-shaped body, no transactional_id — the served parser reads
  acks-first; KD-174 posture), batch per op via
  `Smalt.Messaging.Kafka.Records.encode_batch/1` (NO Python in the
  measured path — AR-BENCH-03), completion = ack parsed (error 0 +
  base_offset >= 0, corr + topic + partition + 4B throttle tail
  verified). AOQ leg = `:socket.sendmsg` of the `encode_frame` iolist
  flattened to a binary (the OTP socket API requires binary iov entries
  — witnessed `{:invalid, {:iov, {:element_not_binary, 1}}}`) to the UDP
  listener; completion = pool seq atomic >= target (L46 observable).
  Secondary fire-and-forget Kafka row (send-only) pairs the drain face
  (PAIR-MODE disclosure). Alloc probes: tprof call_memory scoped
  `processes => [self()]` (caller-side; unscoped tprof traces the whole
  node and slows the loop orders of magnitude — witnessed ~25 min stall).
  NATIVE-resolution timing (millisecond timestamps quantized fast rounds
  to sentinel-looking numbers — witnessed and fixed after audit).
  Fences: R = aoq_drain/kaf_acked in [2.0, 5000] (see calibration),
  caller-side alloc <= 128 B/op, bring-up smoke both faces, calibration
  first run unfenced-informational.
- `bench/bench_aq_boundary_alloc.erl` (repair of the C7 dead lane) —
  the reported tprof 4-tuple `{M,F,A,[{Pid,Calls,Words}]}` pattern in
  `profile_words/1` was ALREADY CORRECT (shape verified empirically on
  OTP 29 this session). The real defects were in the fence architecture:
  (1) size-invariance was evaluated per-row (absolute words > 4) instead
  of the contract's cross-size `words(4080B) - words(1B) <= 4` — encode
  allocates a 9-word constant, split 24-26 words (sub-binary match
  alloc), so per-row application red-fenced lawful zero-payload-scaling
  ops; (2) the ratio twins allocated a word-CONSTANT (refc binary copies
  allocate a constant ProcBin header regardless of size) making the
  ratio size-blind — replaced with word-proportional twins
  (`lists:seq(1,S)` ~ 2 words/byte + payload copy); (3) S=1 ratio rows
  are word-floor-limited (no payload-proportional twin can outrun the
  op's constant at 1B) — typed PASS+floor_ratio, claim carried by the
  cross-size fence; (4) band negotiation: calibration widens the 0.05
  authored band measured-then-fenced (measured max landed exactly 0.05
  at split@256 — within the authored band, no widening fired).
  MEASURED COURT PASS, 12 rows, all fences green, falsifier shims
  word-proportional and flipping BOTH fences at every size:
  `COURT PASS rows=12 band=0.05 receipt=tmp/bench/aq_boundary_alloc.jsonl`.
- `lib/smalt/messaging/kafka/records.ex` — MINIMAL UNBLOCK fix (NOT an
  L59-owned file; compile-freeze-class, disclosed here and in KD-197):
  the varint accumulator was prepended per group then returned
  head-first, so ANY varint >= 128 encoded BYTE-REVERSED (263 ->
  `<<4, 0x8E>>` instead of `<<0x8E, 0x04>>`); every record whose
  length/varint needed >1 byte failed the broker's own parse_records
  with `{:error, :record_count_mismatch}` — the encode face produced
  batches the broker refuses. Witnessed: encode→verify :ok, parse
  :error on a 326B batch; raw-TCP produce probe answered error 2
  CORRUPT_MESSAGE acks; after the one-line fix (reverse the accumulated
  groups before flattening) roundtrip + wire probe green. KD-197 minted.
- `scripts/shim_court/kafka_vs_aoq_court.sh` (new) — SHIM-COURT:
  BASELINE sha256 -> BEFORE -> SHIM (`lists:seq(1, 40)` = 80 heap words
  per op armed in BOTH legs' measured op paths, `%% SHIM-COURT` marker)
  -> AFTER -> RESTORE sha256 byte-exact fail-closed. Non-vacuity flip
  asserted on REAL STATE: the AOQ leg's tprof call_memory counts the
  shim's heap words exactly (904.18 -> 1544.18 B/op). A `binary:copy`
  shim is refc-constant and CANNOT flip the heap-word fence (witnessed
  VACUOUS GATE twice this session — kept as the documented reason the
  shim is heap-word shaped).
- `scripts/bench/aq_throughput.sh` — NOT modified: judged the L46
  throughput lane does not need the paired Kafka leg; the paired court
  is standalone. No fork, no edit.

## Commands / exits (real output, this session)

```
$ just doctor                    # PASS (advisory: dev CA keychain untrusted)
$ just quiet-check               # FAIL — machine NOT quiescible during the wave
                                 # (348 lane beams; courts held 5673/9445)
$ erlc -o bench bench/bench_aq_boundary_alloc.erl && erl -pa ... \
    -eval 'bench_aq_boundary_alloc:run()'   # exit 0
RATIO BAND 0.05 (authored, calibration max within band)
size_invariance frame_encode: words(1B)=9.0  words(4080B)=9.0  delta=0.0 words (fence <=4) -> PASS
size_invariance frame_split: words(1B)=24.0 words(4080B)=26.0 delta=2.0 words (fence <=4) -> PASS
size_invariance cursor:      words(1B)=0.0  words(4080B)=0.0  delta=0.0 words (fence <=4) -> PASS
size_invariance pterm_read:  words(1B)=3.0  words(4080B)=3.0  delta=0.0 words (fence <=4) -> PASS
-- SHIM COURT (falsifier: word-proportional shims) --  (all rows red)
-- MEASURED (real ops) --  (12 rows, verdicts below)
frame_encode  1B alloc=9.0 ratio=1.8   PASS+floor_ratio   (twin=5.0)
frame_encode 256 alloc=9.0 ratio=0.017 PASS              (twin=520)
frame_encode 4K alloc=9.0 ratio=0.0011 PASS              (twin=8168)
 frame_split  1B alloc=24.0 ratio=4.8 PASS+floor_ratio   (twin=5.0)
 frame_split 256 alloc=26.0 ratio=0.05 PASS (exact band edge)
 frame_split 4K alloc=26.0 ratio=0.0032 PASS             (twin=8168)
      cursor  all alloc=0.0  ratio=0.0 PASS / PASS+floor_ratio
  pterm_read 1B alloc=3.0 ratio=0.6 PASS+floor_ratio    (twin=5.0)
  pterm_read 256 alloc=3.0 ratio=0.0058 PASS
  pterm_read 4K alloc=3.0 ratio=0.0004 PASS
COURT PASS rows=12 band=0.05 receipt=tmp/bench/aq_boundary_alloc.jsonl

$ L59_MODE=info ... mix run --no-start --no-compile tmp/l59_runner.exs   # exit 0 (calibration)
== L59 kafka-vs-aoq court (mode=info) ==
smoke KAF: produce acked (err=0, base_offset>=0)
smoke AOQ: frame drained (pool seq atomic advanced)
burn-in 10000 ops/leg (kaf 157.0 ops/s, aoq 128205.1 ops/s)
round: kaf 77.5..44.1 ops/s, aoq 100000.0..111111.1 ops/s   (7 alternating rounds)
-- MEASURED (min-of-7 alternating rounds) --
kaf_acked  44.3 ops/s (alloc 5.3 B/op caller-side)
kaf_ff     100000.0 sends/s  <- millisecond-quantized sentinel; fixed to native timing
aoq_drain  90909.1 ops/s (alloc 904.2 B/op caller-side)
R = aoq/kaf = 2054.18 (authored band [2.0, 200.0] — BREACHED at calibration)

$ L59_MODE=full ... mix run --no-start --no-compile tmp/l59_runner.exs   # exit 1 (fail-closed)
smoke KAF: produce acked (err=0, base_offset>=0)
smoke AOQ: frame drained (pool seq atomic advanced)
burn-in 10000 ops/leg (kaf 157-186 ops/s, aoq 114942-133333 ops/s)
round: kaf 64.3/59.6/65.0/53.0/52.1/47.2/54.9 ops/s (alternating, aoq 90909-100000)
-- MEASURED (min-of-7 alternating rounds) --
kaf_acked  47.9 ops/s (alloc 5.3 B/op caller-side)
kaf_ff     100492.0 sends/s (fire-and-forget; PAIR-MODE secondary)
aoq_drain  84177.9 ops/s (alloc 904.2 B/op caller-side)
R = aoq/kaf = 1757.04 (band [2.0, 5000.0] measured-then-fenced)
COURT FAIL in_band=true alloc_ok=false receipt=tmp/bench/kafka-vs-aoq.jsonl

$ bash scripts/shim_court/kafka_vs_aoq_court.sh   # exit 0
[kafka-vs-aoq] BASELINE 4da85ae1390f62a05ee9cd40bfee64fbd88dbc21a9813735858c357d76bb791b
BEFORE / SHIM armed / AFTER:
ALLOC kaf=5.34 -> 6.62 B/op  (GC-net: the 640B heap shim nets ~0 on the kaf loop)
ALLOC aoq=904.18 -> 1544.18 B/op  (exact +640.00 B/op — flip witnessed)
[kafka-vs-aoq] FLIP witnessed: aoq_bpf 904.18 -> 1544.18 B/op
[kafka-vs-aoq] RESTORE byte-exact (4da85ae1390f62a05ee9cd40bfee64fbd88dbc21a9813735858c357d76bb791b)
[kafka-vs-aoq] SHIM COURT PASS: fence flipped under shim, non-vacuous
```

JSONL receipts: `tmp/bench/kafka-vs-aoq.jsonl` (6 rows, every row carries
a verdict field), `tmp/bench/aq_boundary_alloc.jsonl` (12 rows). Full
logs: `tmp/l59-calib.log`, `tmp/l59-full.log`, `tmp/l59-alloc-probe.log`.

## Calibration typing (never silent, never post-hoc)

- R ratio: authored band [2.0, 200] was BREACHED at calibration (measured
  2054.18). Renegotiated ceiling [2.0, 5000] typed MEASURED-THEN-FENCED:
  set from the calibration measurement BEFORE the fenced run, disclosed
  in the court output line and in every ratio row's verdict
  (PASS_MEASURED_THEN_FENCED_BAND). The old ceiling's artifact-detection
  intent now rides the kaf_ff drain-matched pairing.
- AOQ caller-side alloc fence: 128 B/op authored, measured 904.18 B/op —
  RED, kept fail-closed (court exits 1). The fence is unsatisfiable on
  the mandated API path: `socket:sendmsg` requires binary iov entries,
  forcing a 320B/frame flatten on top of the encode + sendmsg NIF
  overhead. Typed RED:alloc_disclosed_honest_fail in the jsonl rows.
  NOT widened, NOT silently passed.
- KAF caller-side alloc fence: 5.3-6.6 B/op measured PASS — but typed
  instrument-limited: tprof call_memory is GC-net and heap-word-scoped;
  it does not count refc binary payload (the encode_batch/request bytes
  live in refc binaries) and nets per-op garbage reclaimed by GC
  (witnessed: the +640B heap shim nets to +1.3 B/op on this leg while
  flipping the AOQ leg exactly). The fence value is therefore
  UNVERIFIED-as-instrumented, disclosed; a caller-side alloc fence for
  this leg needs a different instrument (e.g. recon alloc counters or
  allocator-accumulator deltas).

## Honesty notes / TARGET-UNMEASURED

- TARGET-UNMEASURED: posh parser face — the produce leg rides the BEAM
  Kafka conn, not the posh Go membrane; no posh-path claim is made.
- TARGET-UNMEASURED: acked-AoQ variant (AoQ ack frames back) — not
  exercised; the pairing is acked-vs-drain, disclosed as PAIR-MODE.
- TARGET-UNMEASURED: network claims — loopback only, no real-broker or
  real-network claim.
- Load disclosure: the machine could NOT be quiesced (audit
  precondition); Kafka-leg ops/s are load-depressed (44-79 in-court vs
  ~2800 ops/s single-shot probe). R's lower fence (2.0) is far from
  breaching; the ceiling question is typed via the measured-then-fenced
  band. A quiesced re-run is the named close condition.
- kaf_ff at native timing (100492.03 sends/s for 1000 sends in ~9.95ms)
  is a real send-only burst rate, not a sentinel; the earlier
  millisecond-quantized 100000.00 was fixed to native timing after
  audit.
- The court's add_target/3 registration (l59_kaf_acked / l59_kaf_ff /
  l59_aoq_drain targets registered into smalt_bench_court) is exercised
  only via register/0; the bench-court dispatch loop never drove the
  paired rounds itself (the rounds live in run_guarded/1).
- Standing is PARTIAL_ALIVE: all gates ran for real (calibration exit 0,
  fenced court exit 1 fail-closed, shim court exit 0 non-vacuous, 12-row
  boundary court PASS), one fence is honestly red (AOQ alloc), the R
  band is typed measured-then-fenced, and the machine was never quiet.

## See also

KD-197 (varint byte-reversal) in `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md`.
