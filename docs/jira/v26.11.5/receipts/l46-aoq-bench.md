# L46 — AoQ bench lane: listener→pool→worker end-to-end throughput

Standing: ALIVE

Subject: `/Users/sac/smalt` — first AoQ bench lane
(`scripts/bench/aq_throughput.sh`), exercising the real AoQ plane path:
SMALT_PLANES=aoq boot (az_prod_aoq profile flips `config :smalt, :aoq,
enabled: true`; DataSupervisor mounts Smalt.Aoq.Supervisor =
NifHolder → WorkerPool → Listener), UDP frames pushed through the listener
(encoded via `Smalt.Aoq.Frame.encode_frame` — 64B header + 512B payload =
576B frames, framing law honored), end-to-end frames/sec (send → pool seq
atomics → every worker mailbox drained) + iolist-egress alloc delta
(encode_frame iolist vs flat-binary concat baseline, GC-bounded
process-memory bytes/frame).

## Diff

- `scripts/bench/aq_throughput.sh` (new) — bash lane per scripts/bench
  conventions: sources `scripts/bench/lib.sh`, emits via `bench_emit` to
  ITS OWN result file `tmp/aq-throughput.jsonl` (underscore script, hyphen
  jsonl). Port law: lane L46 block 39460..39465 (39000 + 10*46); AoQ
  listener pinned to +5 (39465) via config override (collision law: shared
  substrate may hold 9093); data-plane co-listeners stay on the
  MIX_ENV=test probed-free ports. No lib/ edits, no shared-file edits.
- Bench body generated at runtime to `tmp/l46_bench.exs` (single beam:
  boot + measure + halt; bash bounded-polls the metrics file as the
  run-completed observable).

## Commands / exits (real output, this session)

```
$ L46_N=20000 L46_ROUNDS=5 ./scripts/bench/aq_throughput.sh   # exit 0
[l46] booting AoQ plane (planes=aoq, aoq listener 39465, egress 39461), N=20000 x5 rounds...
[l46] measured: min 120650.8 frames/s, avg 130102.1 frames/s | rounds: seq0:131122.9fps(0.153s) seq20000:120650.8fps(0.166s) seq40000:126399.9fps(0.158s) seq60000:127998.2fps(0.156s) seq80000:144338.7fps(0.139s) | alloc delta 29.95 B/frame
[l46] results: /Users/sac/smalt/tmp/aq-throughput.jsonl
```

Result records (tmp/aq-throughput.jsonl, bench_emit shape, machine
Apple M3 Max 16c/48GB, elixir 1.20.4 / otp 29 / darwin 26.2):

- udp_ingest_drain_min  = 120650.8 frames/s (min-of-5, headline, ratio-fence)
- udp_ingest_drain_avg  = 130102.1 frames/s
- iolist_encode         = 1898932.9 encodes/s (p50 0.0002ms / p95 0.0003ms /
  p99 0.013ms)
- iolist_egress_alloc_bpf = +29.95 B/frame (iolist encode_frame alloc MINUS
  flat-binary-concat baseline, GC-bounded per-frame process-memory delta;
  positive = the iolist shape allocates ~30B/frame MORE than concat for this
  64B-header + 512B-payload frame — the two-segment iolist header build, not
  a payload copy)

## Honesty notes

- End-to-end "drain" observable = pool seq atomics reached target AND every
  worker mailbox empty (real observables; the ingest window includes send +
  listener + pool + worker parse through the NifHolder stub — a real NIF
  landing will move this number).
- Ingest-window p50/p95/p99 are emitted 0.0 (no per-frame latency sample on
  the unacked datagram path); the per-frame latency percentiles ride the
  iolist_encode op instead. Not hidden: stated here.
- One earlier run TYPED-TIMEOUTed in the drain poll under machine contention
  (20-lane fleet on one box); the poll now carries a 2ms `receive after`
  POLL-STEP (SLEEP-CLASS: POLL-STEP, bounded deadline, typed timeout) and
  the rerun passed clean. The timeout path is fail-loud BLOCKED, never a
  fake pass.
- Toolchain pinned in-script (asdf elixir 1.20.4-otp-29 / erlang 29.1.2 per
  .tool-versions); the ambient 1.19.5 is refused by mix.exs.

## Standing

ALIVE — real measured numbers above (min-of-5 headline 120650.8 frames/s,
alloc delta 29.95 B/frame), exit 0, result jsonl on disk
(/Users/sac/smalt/tmp/aq-throughput.jsonl), bounded rounds, min-of-N.
Load-harness ambitions (sustained saturation) stay out of scope per the
dispatch: not a load harness.
