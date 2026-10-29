# BENCH-6 — native :json SAX streaming (pure Erlang)

**Standing:** **ALIVE**
Context: solo

## Subject

- Module: `/Users/sac/smalt/bench/bench_json_streaming.erl`
  (build root `_bench-json/`, pure Erlang, stdlib `:json` only)
- Result jsonl: `/Users/sac/smalt/tmp/bench/court_bench_json.jsonl`
  (single row, lane `bench6-json`, op `json_sax_stream`)

## Executed

```
erlc -o _bench-json bench/bench_json_streaming.erl
erl -pa _bench-json -noshell -s bench_json_streaming menu -s init stop
# exit=0
```

Corpus: deterministic synthetic Cosmos-style doc array, 52,692,552 bytes
(50.3 MiB), 22,551 docs, phash2-of-fixed-tuple (no RNG). Streaming via
`json:decode_start(Head, 0, Decoders)` + `json:decode_continue(Chunk, St)`
with the T42-verified arity-specific discard hooks (array_start/1, array_push/2,
array_finish/2, object_start/1, object_push/3, object_finish/2, integer/1,
float/1, string/1, null), 64KB chunks, isolated worker, GC before exit,
1ms `total_heap_size` poller.

## Results (3 runs, isolated worker)

| run | wall ms | peak heap B |
|---|---|---|
| 1 | 83 | 38,504 |
| 2 | 81 | 20,744 |
| 3 | 80 | 20,696 |

min wall 80ms · aggregate 244ms · max peak heap 38,504 B (37.6 KiB) · errors 0

## Gate verdict

- ARD heap gate (≤2MB peak): **MET** (38.5 KiB, ~1.8% of budget)
- ARD wall gate (≤100ms per 50MB): **MET** (80ms min, 83ms max)
- T42 comparison (97ms / 23KB): wall **beats** T42 (80ms < 97ms); peak heap
  same class (38.5 KiB vs 23KB, both ~3 orders below the 2MB gate)
- Verdict: **PASS** (row in jsonl, exit 0)

Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Notes

- One corpus defect was caught and fixed during the run: the `docs` array
  wrapper was missing `[`, surfacing as `json:{invalid_byte,123}` at the
  first doc boundary — fixed in `corpus/1` before the recorded runs.
- jsonl field order is hand-built (no Jason in a pure-Erlang lane); parsed
  back with `python3 -m json` — valid single JSON object.
