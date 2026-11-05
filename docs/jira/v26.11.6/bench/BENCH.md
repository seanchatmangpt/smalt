# BENCH — v26.11.6 wave+1 BC lane (bench-conversion)

Standing: PARTIAL_ALIVE

Converts three unpinned perf claims into measured, fenced benches over the
REAL landed modules (Chicago: real collaborators, real collaborators' state —
real ETS sink, real journal, real atomics cursors; no mocks). Harness:
`smalt_bench_court:run_benchmark/3` (monotonic wall clock + caller-side
reduction accounting), paired min-of-7 rounds per side.

## Machine + toolchain (as-run)

- Apple M3 Max, 16 cores, 48 GB RAM, macOS 26.2
- asdf elixir 1.20.4-otp-29 / OTP 29 (pinned toolchain; note:
  `scripts/bench/lib.sh bench_machine_spec` reports Homebrew
  elixir 1.19.5/otp28 from PATH — not this bench's toolchain)
- Beams: `_build-laneKG/dev/lib` (read-only lease borrow; the shared source
  tree has a foreign mid-flight break in `lib/smalt/aoq/arrow/flatbuf.ex`
  that refuses a fresh `mix compile` — disclosed per the both-receipt law,
  not repaired by this lane)

## Census: unpinned perf claims in the landed surfaces

| claim (owning lane) | status |
|---|---|
| durable-offset restart-under-load (L2) | TARGET-UNMEASURED (court exists; load numbers unbenched) |
| GroupManager rebalance latency (L1) | TARGET-UNMEASURED |
| per-partition-ring throughput vs stateless pool (L5) | PINNED (BC2) |
| SASL handshake overhead (L10) | kernel-only PINNED (BC1); full-socket loopback handshake TARGET-UNMEASURED |
| PartitionLog produce/fetch throughput (L6) | PINNED (BC3: produce + fetch absolutes, engine-vs-journal-floor ratio) |
| RDF projector batch latency (L16) | TARGET-UNMEASURED |
| admission fold-then-bisect per-batch cost (L9) | TARGET-UNMEASURED |
| PartitionLog fetch scaling (BC3 fetch) | measured at ~4k stored batches; fetch is a tab2list scan (O(table)) — scaling law unbenchmarked |

## Results (fenced run, exit 0)

Source: `bc.jsonl` (this dir); fences `bc_fences.json` (calibration-derived,
never post-hoc; headroom 10x upper-bound fences / 0.5x lower-bound fence).
Row fields: n per round, min wall clock over 7 rounds, ops/sec at the min,
caller-side reds/op (GenServer-side work is NOT in caller reds — disclosed).

| bench | n | ops/sec | ns/op | reds/op | note |
|---|---|---|---|---|---|
| bc_sasl_plain_admit | 200000 | 4.31M | 232 | 15.0 | SASL PLAIN parse_plain+authenticate (L10 kernel) |
| bc_plaintext_admit | 200000 | 223M | 4.5 | 4.0 | plaintext baseline (zero admission work) |
| bc_ring_submit | 20000 | 532k | 1879 | 129 | 4 real rings, real cursor atomics + sends |
| bc_pool_submit | 20000 | 623k | 1605 | 274 | real WorkerPool round-robin dispatch |
| bc_partitionlog_produce | 2000 | 35.3k | 28303 | 2717 | full engine incl. journal + ETS + hwm |
| bc_journal_floor_append | 2000 | 24.5k | 40821 | 3545 | raw JournalSink.append (journal floor) |
| bc_partitionlog_fetch | 500 | 172 | 5.83M | 438529 | fetch over ~4k stored batches (scan) |

## Fence verdicts (this run)

| fence | kind | measured ratio | verdict |
|---|---|---|---|
| bc_sasl_overhead_max (<= 524.3x) | max | 51.8x | pass |
| bc_ring_pool_ratio_min (>= 0.295x) | min | 1.17x | pass |
| bc_log_engine_overhead_max (<= 3.49x) | max | 0.69x | run2 0.69 / calibration 0.35 / spot 1.07 — pass with disclosed variance |

## Honest findings

- SASL PLAIN admission kernel cost is ~52-55x an empty admit but only
  ~232 ns/op at 4.3M admissions/sec — the handshake tax is negligible
  per-connection; full-socket loopback handshake: TARGET-UNMEASURED.
- Ring vs pool submit hot path: same order of magnitude (~0.53-0.62M
  ops/sec combined-side), but the ring/pool ratio drifts run-to-run
  (0.59x, 1.07x, 1.14x, 1.17x, 1.44x observed) — the submit hot path is
  send/scheduling-dominated; the min-of-7 fence (>= 0.295x) held in all
  real runs, and the non-vacuity probe (fence inflated to 5.0) FAILed
  exit 1 with byte-exact fence restore (sha256 3720873578601a738da8ade3
  ad7124f396dd94d939a95a1c9e597cc397f14f0a).
- PartitionLog produce (35.3-56.6k ops/sec across runs) is 0.59x-1.07x of
  the raw journal floor — the engine seams (parser/guard/fanout) are not
  the bottleneck; the journal append is. Fetch is a tab2list scan — 172
  ops/sec at ~4k batches; a fetch scaling bench is future work.
- Registering a claim "ring faster than pool" (or the reverse) from these
  numbers is an OVERCLAIM: the pair is scheduling-noise-dominated at these
  rates. The lawful claim: both hot paths sustain >0.45M submit-ops/sec
  caller-side on this host.
