# Receipt: bench-07-store-beam (lane B-7)

- **Date**: 2026-10-15
- **Subject**: `/Users/sac/smalt` @ `518b31a54ccc0829cafb9e04538714e58c287a30` (main), working tree.
- **Lane**: B-7 — BEAM-level Store microbenchmarks (raw ETS/GenServer, no SDK, no HTTP).
- **Script**: `scripts/bench/b7_store_beam.exs`
- **Results**: `docs/jira/v26.10.14/bench/b7-store-beam.jsonl` (27 records)
- **Method**: `MIX_ENV=test mix run --no-start scripts/bench/b7_store_beam.exs` — boots only
  `Smalt.Store.start_link/1` (public `:ordered_set` ETS tables, read/write_concurrency);
  no full substrate. `:erlang.monotonic_time` wall timing, 100-op warmup per bench,
  keys unique per batch. 120k ops per throughput bench. Latency sampled every 50th op.
- **Machine**: Apple M3 Max, 16 schedulers / 16 logical, OTP 28, Elixir 1.19.5, macOS 26.2.

## Headline numbers (second run, first run in run1 agreement within ~5%)

| op | n | ops/sec | p50/p95/p99 (ms) | errors |
|---|---|---|---|---|
| put | 120,000 | **1,037,470** | 0.001 / 0.002 / 0.005 | 0 |
| get | 120,000 | **1,828,098** | 0.001 / 0.001 / 0.002 | 0 |
| compare_and_swap (single-writer) | 120,000 | **282,350** | 0.003 / 0.004 / 0.004 | 0 CAS conflicts |
| concurrent put+get, 32 procs | 512,000 ops | **15,742,705** | — (aggregate) | 0 |
| list_prefix full scan, 10k keys | 10,000 | 6.404 ms full scan (**1.56M keys/sec**) | — | 0 |
| insert_new 64-racer | 20 rounds | **exactly one winner / 63 `{:error, :exists}` every round** | 0.42–1.46 ms per round | 0 |

BEAM meta: 16 schedulers, OTP 28.

## Reading

- put/get are direct public-ETS ops (~1M w/s, ~1.8M r/s single-process, p99 <= 5 us) —
  this is the BEAM floor; every SDK number sits on these.
- CAS goes through the Store GenServer (`GenServer.call` round-trip) at ~282k/s — the
  serialization is the price of the atomic check-and-insert/replace guarantee, and it
  still delivers exactly-one-winner under 64 concurrent racers, 20/20 rounds.
- Concurrent 32-process mixed put+get scales ~15x over single-process put — public ETS
  with write_concurrency scales near-linearly on 16 schedulers.

## Falsifier status

- insert_new exactly-one-winner: falsified 0/20 rounds — guarantee holds.
- CAS conflicts under single-writer: 0 — monotone write path is conflict-free.

## Standing

ALIVE — executed on the exact subject; JSONL + this receipt on disk.

## Re-witness 2026-10-16

```
$ MIX_ENV=test MIX_BUILD_ROOT=_build-lane316 mix run --no-start scripts/bench/b7_store_beam.exs 2>&1 | tail -12
{"lane":"b7","surface":"store-beam","op":"insert_new_race_64","round":10,"n":64,"winners":1,"losers":63,"ok":true,"total_ms":1.079}
...rounds 11..19 identical shape (winners=1, losers=63, ok=true, 0.649-0.996 ms)...
{"lane":"b7","surface":"store-beam","op":"insert_new_race_64","round":20,"n":64,"winners":1,"losers":63,"ok":true,"total_ms":0.444}
{"lane":"b7","surface":"store-beam","op":"done"}
exit=0
```

Exactly-one-winner guarantee re-witnessed 20/20 rounds on the current tree
(`_build-lane316` private build root, no substrate). Full output in session log;
the 20 rounds re-run end-to-end, exit 0.
