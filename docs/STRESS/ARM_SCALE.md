# ARM_SCALE

Measured ARM control-plane scaling behavior of the smalt substrate at
20k resources. Harness: `scripts/stress/arm_scale.py` (stdlib-only,
fail-closed, boots its own substrate, writes
`tmp/arm-scale-receipt.json`).

    python3 scripts/stress/arm_scale.py

The substrate is spawned on dedicated ports (ARM 19443, TLS 19444,
egress 18443, AMQP 15672/15673) via `Application.put_env` injection so
the run never collides with another live substrate or lane on the
default ports, and tears it down (process-group SIGKILL + port sweep
restricted to its own ports) in a `finally`.

## Run conditions

- Bearer-enforced (`:auth_mode :enforce`, dev default); the harness
  mints one token from the substrate's own STS (`POST /oauth2/v2.0/token`,
  3600 s TTL) and sends it on every request.
- 1 subscription, 200 resource groups, 20,000
  `Microsoft.EventGrid/topics` resources (DefaultShape, non-LRO,
  api-version 2021-04-01), bucket plan 90 RGs x 10 + 101 RGs x 100 +
  9 RGs x 1000 = 20,000 across exactly 200 RGs.
- 32 PUT threads, per-thread persistent keep-alive connections.
- Receipt on disk: `tmp/arm-scale-receipt.json`
  (run 2026-10-14T21:45:12-0700, darwin/arm64 local).

## Results

| Measurement | Result |
|---|---|
| Resource PUT throughput | 8,572 rps (20,000 PUTs in 2.33 s, 32 threads) |
| Resource PUT latency | p50 0.60 ms, p95 4.93 ms, p99 7.26 ms, max 13.4 ms |
| RG collection LIST (all 200, single page) | p50 0.81 ms, p99 1.33 ms |
| Per-RG provider LIST @ 10 children | p50 11.1 ms |
| Per-RG provider LIST @ 100 children | p50 11.6 ms |
| Per-RG provider LIST @ 1000 children | p50 12.5 ms |
| ResourceGraph unfiltered `$top 100` | p50 36.5 ms, p99 44.0 ms; count=100, total=20000, $skipToken present |
| ResourceGraph subscription-filtered | p50 61.2 ms, p99 90.1 ms |
| GET single resource | p50 0.185 ms, p95 0.25 ms, p99 0.41 ms |
| api-version GET valid vs missing | +0.009 ms median delta (0.171 vs 0.162 ms) |
| PUT wrong api-version (typed rejection) | p50 0.185 ms — validation is not measurable overhead |
| RSS before / after load | 197.7 MB / 263.2 MB (+65.6 MB for 20k resources, ~3.3 KB/resource) |

## Findings

1. **Per-RG LIST is O(total table), not O(children).** The
   10/100/1000-child curve is essentially flat (11.1 -> 12.5 ms) while
   an RG collection LIST at the same table is 0.81 ms: the cost floor is
   `Store.prefix_keys/2`, which walks the entire `:smalt_resources`
   ordered_set (all 20k keys) from table start and filters. Child count
   does not matter; total inventory does. Cost scales with future
   inventory growth, not result size. A `:ets.prev/2` seek to the prefix
   start would bound the walk to the prefix.
2. **Single-resource GET is scale-free.** p99 0.41 ms at 20k keys
   (`Store.get/2` is a plain `:ets.lookup`, O(log n)); the
   `list_prefix` full-walk concern does not apply to point reads.
3. **ResourceGraph scans dominate at scale.** Every query materializes
   the full 20k-row inventory (`Store.list/1` + per-row KQL/paging), so
   a paged `$top 100` read costs ~37 ms unfiltered and ~61 ms with a
   subscription filter (the filter adds a MapSet pass over all rows).
   Pagination itself is cheap; the scan is the cost.
4. **api-version validation is free.** Valid vs missing vs wrong-version
   rejection all sit within 0.02 ms of each other.
5. **Memory is predictable**: ~3.3 KB of RSS per stored resource.

## Reproducing

    python3 scripts/stress/arm_scale.py

Exit code 0 requires every phase to complete with expected status
codes (200/201 PUTs, 200 lists/queries, 400 validation rejections);
any fault kills the substrate and exits non-zero. Adjust `N_RESOURCES`,
`N_RGS`, `BUCKETS`, `PUT_THREADS`, and the repetition counts at the top
of the script.

## See Also

`scripts/bench.py` (single-shot CTQ bench), `scripts/stress/` harness
conventions.
