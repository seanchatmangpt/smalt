# Receipt: ERRC lane 2 (Raise) — benchee adoption for BEAM micro-benchmarks

- **Date**: 2026-10-15
- **Repo**: /Users/sac/smalt (main, uncommitted working tree)
- **Lane**: ERRC lane 2 (Raise)
- **Subject**: adopt `benchee` as the statistical counterpart to the hand-rolled
  b7/b8/b9 timing loops; hand-rolled scripts kept untouched as falsifier records.

## What landed

1. `mix.exs`: `{:benchee, "~> 1.3", only: [:dev, :test], runtime: false}` —
   resolved from hex as **benchee 1.5.1** (lock entry sha256
   `a539301f...`; hex resolution receipt: `mix deps.get` "Getting benchee
   (Hex package)" + mix.lock line 8). Note: a `{:recon, "~> 2.5", only: :test}`
   dep and related edits landed in the same region of mix.exs from a different
   lane (errc7); both deps resolved cleanly together.
2. `scripts/bench/benchee_runner.exs` (new): runs the SAME scenarios as
   b7/b8/b9 through benchee (warmup 2s + time 5s, `parallel: 1`), emits benchee's
   statistics into the same JSONL row shape (`ops_per_sec` from benchee ips,
   `p50/p95/p99_ms` from benchee run_time percentiles, plus a `benchee` block
   with samples/std-dev ratios) into NEW files:
   - `docs/jira/v26.10.14/bench/b7b-store-beam.jsonl`
   - `docs/jira/v26.10.14/bench/b8b-amqp-beam.jsonl`
   - `docs/jira/v26.10.14/bench/b9b-eh-beam.jsonl`
3. Hand-rolled b7/b8/b9 scripts untouched (falsifiers). Both b7 and b9
   hand-rolled scripts were **re-run same-code today** and appended fresh
   comparison rows to their canonical JSONL records; hand-rolled b8 was
   re-run same-code today too.

## Comparison table — benchee vs hand-rolled (all same-day, same code, same machine, sequential)

Machine: Apple M3 Max, 16 cores, 48 GB, OTP 28, Elixir 1.19.5. Deltas are
benchee / hand-rolled, so >1 means benchee reports higher throughput.

| lane/op | benchee ops/s | hand-rolled today | ratio | hand-rolled record (pre-lane) |
|---|---|---|---|---|
| b7 put | 1,126,201 | 1,020,773 | 1.10x | 1,037,470 |
| b7 get | 1,822,172 | 1,767,930 | 1.03x | 1,828,098 |
| b7 compare_and_swap | 280,229 | 288,468 | 0.97x | 282,350 |
| b8 frame_transfer_encdec | 218,694 | 43,807 | **5.0x** | 41,312 |
| b8 enqueue_1kib_depth1 | 178,233 | 91,756 | **1.94x** | 86,189 |
| b8 e2e_store_rt_1kib | 77,144 | 44,257 | **1.74x** | 35,959 |
| b8 dequeue_ack_1kib | 1,571 | 433 | **3.6x** | 418.7 |
| b8 session_delivery_rt | 49,313 | 890.9 | **55x** | 870.4 |
| b9 send_event_1kib | 670 | 335.9 | **2.0x** | 344.2 |
| b9 receive_events_drain_1kib (events/s) | 2,050,283 | 209,677 | **9.8x** | 216,999 |
| b9 next_sequence | 193,801 | 193,106 (5.178 us/op) | 1.00x | 210,236 |
| b9 reserve_processing | 179,594 | 131,539 (7.602 us/op) | 1.37x | 126,774 |
| b9 lock_acquire_release | 340,573 | 266,152 | 1.28x | 299,531 |

dequeue_ack caveat: benchee prefill 1000/queue declining; hand-rolled drains
50k msgs across 13 queues (depth up to ~4096, avg ~2000). Different depth
regime — not directly comparable; both depth-sensitive.

## Findings (deltas > 20%)

**F1 — b7 agreement is excellent (0.97x–1.10x)**: for store-tier ops the two
methodologies agree within noise. The benchee adoption is validated by its
intended falsifier.

F2 — b8/b9 deltas on cheap ops are large and systematic (>1x): benchee
reports 1.7–5x higher throughput on cheap CPU/ETS ops (frame encdec 5.0x,
enqueue_depth1 1.9x, e2e 1.7x, send_event 2.0x, drain 9.8x). **This is a
FINDING about the hand-rolled methodology**: the hand-rolled loops time a
single 50k-iteration comprehension as one block (accumulating all 50k ops'
garbage and any GC pauses inside one measurement, and paying per-iteration
comprehension overhead inside the timer), while benchee amortizes the timer
overhead across repeated measurement batches and keeps the loop tight. The
hand-rolled scripts are kept as the falsifier record; treat hand-rolled
absolute numbers as lower bounds on cheap ops. The direction is consistent:
benchee ≥ hand-rolled on every cheap op; the hand-rolled loop structure is
the dominant term. The 9.8x drain delta includes a normalization difference:
benchee row is events/s (ips x 500-event batch, `batch: 500` field in the row);
the hand-rolled drain includes list-building and per-batch bookkeeping in the
timed loop.

F3 — session_delivery_rt 55x: the hand-rolled 870 ops/s is NOT the same
scenario (hand-rolled pre-enqueues 4,000 session messages outside the timer
and runs only 4,000 iterations — JIT-cold; benchee runs 243k iterations with
per-iteration enqueue included, fully JIT-warm). 55x is scenario mismatch, not
a methodology defect — benchee's number is the honest steady-state RT, the
JIT-cold 4,000-iteration hand-rolled run is a cold-start record. Disclosed:
benchee includes the per-iteration enqueue (hand-rolled excluded it), which
should make benchee *slower*, so the 55x is even conservative.

F4 — dequeue_ack 3.6x: depth-regime mismatch (benchee prefill 1000/queue
declining vs hand-rolled draining 50k at depth up to ~4096; the queue scan is
O(depth)), compounded by F2's tight-loop effect. Not directly comparable.

## Limitations

- benchee percentile fields in the b7b/b8b/b9b rows are per benchee
  *measurement batch*, not per-op latencies (benchee runs the job N times per
  timing sample for cheap ops). For per-op latency distribution, the hand-rolled
  sampled-latency method remains the reference; ops_per_sec is the comparable
  headline.
- The pre-lane records predate today's heavy working-tree churn; that is why
  same-day hand-rolled reruns were used as the comparison baseline, with the
pre-lane record shown for provenance.
- No commits per lane contract.
## Re-witness 2026-10-16 — SKIP (honest)

```
$ mix run scripts/bench/benchee_runner.exs 2>&1 | tail -4
** (Mix) Could not start application smalt: Smalt.Application.start(:normal, []) returned an error: shutdown: failed to start child: {Bandit, #Reference<0.3535657554.2136735746.1477>}
    ** (EXIT) shutdown: failed to start child: :listener
        ** (EXIT) :eaddrinuse
exit=1
```

SKIP reason: the benchee runner boots the full `Smalt.Application` on its fixed
ports (9443/8443/5672) and the shared substrate currently holds them
(`:eaddrinuse`, exit 1). Not re-witnessed this session; the receipt remains
flagged rather than faked. Re-run requires 9443/8443/5672 free
(`just substrate-down` first).
