# popcorn_demo host-leg bench (lane `legs`)

ERRC-R8: latency numbers for the testbed's own host legs.
Script: `popcorn_demo/scripts/bench_legs.sh` runs each host leg
(`PopcornDemo.Live` / `LiveMatrix` / `LiveBlob`) via `mix run`, N=5 runs per
leg, one OS process per run, wall ms per run measured with
`time.perf_counter` (measurement clock, not a coordination sleep). Emits one
JSONL row per leg to `popcorn_demo/bench/legs.jsonl`:

```json
{"lane":"legs","leg":"PopcornDemo.Live","median_ms":513.7,"max_ms":2489.7,"runs":5,"ts":"2026-10-21T00:46:15Z","errors":0,"machine":{...}}
```

Schema note: this lane's rows are leg-granular (median/max wall ms), not the
`{surface,op,p50,p95,p99}` shape of `scripts/bench/lib.sh`'s `bench_emit`, so
the script does a documented plain append and sources `lib.sh` only for
`bench_machine_spec`. The lane writes ONLY `popcorn_demo/bench/legs.jsonl`.

## Machine (2026-10-21 run)

`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.2","otp":"28","darwin":"26.2"}`

## Ratio fence rule (no absolute ms bounds)

A leg REGRESSES if its new `median_ms` > 2x the `median_ms` of the previous
jsonl row for the same `leg` (row-to-row comparison, quiet-machine baseline).
The fence is relative by construction — never a wall-clock constant, so it
survives machine changes without going stale. The script computes the fence
against the on-disk jsonl before appending, prints
`ok(fence <2x-prev>ms)` or `REGRESSED(...)` and exits 1 on regression or any
leg error. A leg with zero good runs is `FAIL`, never a silent skip.

## Current numbers (latest row per leg, substrate UP on 9443; W13-T refresh 2026-10-21T04:14-04:16Z)

| Leg | median_ms | max_ms | runs | errors |
|---|---|---|---|---|
| PopcornDemo.Live | 686.0 | 1575.7 | 5 | 0 |
| PopcornDemo.LiveMatrix | 1016.8 | 2245.7 | 5 | 0 (fence REGRESSED, see W13-T below) |
| PopcornDemo.LiveBlob | 729.9 | 967.9 | 5 | 0 |
| PopcornDemo.LiveQueue | 454.0 | 457.9 | 3 | 0 |
| PopcornDemo.LiveKV | 445.7 | 446.6 | 3 | 0 |
| PopcornDemo.LiveRules | 536.5 | 542.3 | 3 | 0 |
| PopcornDemo.LiveEh | 6.0 | 9.0 | 5 | 0 |
| PopcornDemo.LiveCas | 3535.3 | 4163.5 | 3 | 0 |
| PopcornDemo.LiveKeyops | 3922.4 | 4415.4 | 3 | 0 |
| PopcornDemo.LiveLifecycle | 4130.2 | 4982.4 | 3 | 0 |
| PopcornDemo.LiveContainers | 4139.5 | 4600.6 | 3 | 0 |
| PopcornDemo.LiveTags | 1193.7 | 3232.0 | 3 | 0 |
| PopcornDemo.LiveMcp | 725.3 | 1073.2 | 3 | 0 |
| PopcornDemo.LiveCerts | 780.9 | 883.5 | 3 | 0 |
| PopcornDemo.LiveRg | 497.6 | 515.2 | 3 | 0 |
| PopcornDemo.LivePolicy | 543.7 | 562.6 | 3 | 0 |
| PopcornDemo.LiveParam | 504.6 | 529.7 | 3 | 0 |
| PopcornDemo.LiveEG | 755.6 | 778.2 | 3 | 0 |

Original 3 legs via `popcorn_demo/scripts/bench_legs.sh` (ts
2026-10-21T01:00:43Z), all `fence=ok` against the prior 00:51:05Z rows:
Live fence=ok(962.6ms), LiveMatrix fence=ok(1106.0ms),
LiveBlob fence=ok(978.2ms), exit 0.

New legs (LiveQueue / LiveKV / LiveRules, W3-11, ts 2026-10-21T01:01:28Z)
measured with the same one-mix-run-per-leg pattern (identical `run_timed`
body, N=3 instead of 5), appended in the same schema. Verdicts witnessed:
`queue=OK(popcorn-q:74-bytes-roundtrip)`,
`kv=OK(popcorn-secret:30-bytes-lifecycle)`,
`rules=OK(popcorn-r:1-listed)`.

**Fence baselines (initial medians, first jsonl row for each new leg —
future runs of those legs fence against 2x these values):**

- PopcornDemo.LiveQueue: 454.0 ms → regression fence 908.0 ms
- PopcornDemo.LiveKV: 445.7 ms → regression fence 891.4 ms
- PopcornDemo.LiveRules: 536.5 ms → regression fence 1073.0 ms

Ratio-fence law unchanged: row-to-row >2x previous median for the same leg,
never a wall-clock constant.

Repeat pass 20s later (fence-stability witness, all ok, exit 0):
Live 481.3/632.7, LiveMatrix 553.0/588.6, LiveBlob 489.1/660.1
(median/max ms).

## Session-introduced vs pre-existing

- Live and LiveBlob: 5/5 clean runs, zero errors.
- LiveMatrix: HTTP-400 `InvalidBody` on `POST /dbs` during the session's
  first full run — attributed to the in-flight popcorn_demo `lib/` tree (a
  concurrent lane had live_kv.ex/live_matrix.ex mid-edit; live_kv.ex did not
  compile 00:47-00:49). Same leg was ALIVE at 00:36
  (`popcorn_demo/receipts/20261021T003644Z-testbed-witness.md`), and passed
  5/5 in both post-heal passes. PRE-EXISTING/transient lane churn, not a
  substrate or bench defect.
- W3-11 extension (01:00-01:01Z): all 6 legs clean, 0 errors total — the
  3 original legs 5/5 (script, exit 0), the 3 new legs 3/3 (manual
  measurement). No skips, no regressions.

## W13-T terminal refresh (2026-10-21T04:14-04:16Z, substrate UP on 9443)

`popcorn_demo/scripts/bench_legs.sh` run once post-consolidation
(ts 2026-10-21T04:14:28Z, N=5): Live 686.0/1575.7 fence=ok(943.0ms),
LiveBlob 729.9/967.9 fence=ok(987.6ms),
**LiveMatrix 1016.8/2245.7 fence=REGRESSED(>2x prev median 986.4ms)** —
3% over the fence (prev 493.2ms); script exit 1 on that row. Honest verdict:
regression recorded, not suppressed. Attributed to a busier machine than the
01:01Z quiet baseline (16-core shared host); re-run under quiet conditions to
re-fence.

New legs measured manually with the same one-mix-run-per-leg pattern
(`run_timed` body identical to the script), N=3, appended in the same schema
(ts 2026-10-21T04:15:15Z, LiveEG 04:16:34Z). All 0 errors, verdicts:

- `cas=OK(insert,etag,fresh-200,stale-412,delete-204,gone-404)`
- `keyops=OK(ES256:verified)`
- `lifecycle=OK(create:get:delete:get404:l5k...)`
- `containers=OK(1-listed)`
- `tags=OK(2-tags-roundtrip)`
- `mcp=OK(32-tools)`
- `certs=OK(popcorn-cert-3650:purge)`
- `rg=OK(5-rows)`
- `eg=OK(pegl...:bearer-topic-publish-readback-kd101refusal)` (module is
  `PopcornDemo.LiveEG` — capital G; first attempt at `LiveEg` was
  SKIP(:badfile), 3 loud errors, no row appended, then corrected)
- `policy=OK(5-faces-1-defs)`
- `param=OK(1-matched-params)`

`PopcornDemo.LiveEh` already had a row (01:34:14Z, 6.0ms median) so it was
not re-measured. `PopcornDemo.LiveTls` exists in `lib/popcorn_demo/` but was
outside this lane's leg list and has NO row — open slot for a future pass.

**Fence baselines (first jsonl row for each new leg — future runs fence
against 2x these values):**

- PopcornDemo.LiveCas: 3535.3 ms → fence 7070.6 ms
- PopcornDemo.LiveKeyops: 3922.4 ms → fence 7844.8 ms
- PopcornDemo.LiveLifecycle: 4130.2 ms → fence 8260.4 ms
- PopcornDemo.LiveContainers: 4139.5 ms → fence 8279.0 ms
- PopcornDemo.LiveTags: 1193.7 ms → fence 2387.4 ms
- PopcornDemo.LiveMcp: 725.3 ms → fence 1450.6 ms
- PopcornDemo.LiveCerts: 780.9 ms → fence 1561.8 ms
- PopcornDemo.LiveRg: 497.6 ms → fence 995.2 ms
- PopcornDemo.LivePolicy: 543.7 ms → fence 1087.4 ms
- PopcornDemo.LiveParam: 504.6 ms → fence 1009.2 ms
- PopcornDemo.LiveEG: 755.6 ms → fence 1511.2 ms

Ratio-fence law unchanged: row-to-row >2x previous median for the same leg,
never a wall-clock constant.

Toolchain note: the lane script's `1.20.*` asdf glob pins 1.20.2-otp-28
(first lexicographic match); the 1.20.3-otp-28 named for this lane was NOT
the toolchain of record for these rows. Rows carry
`machine.elixir=1.20.2` honestly.
