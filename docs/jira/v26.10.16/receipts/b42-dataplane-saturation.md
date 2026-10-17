# Receipt: lane b42 — data-plane saturation pipeline (10,000-request storm)

Standing: **ALIVE** (single green run, exit 0; asserts held: 0 dropped connections, 0 read-your-write violations)

Date: 2026-10-16 · Lane: b42 (ports 39420-39425) · Build root: `_build-lane502`

## Subject

`/Users/sac/smalt/scripts/bench/b42_dataplane_saturation.exs` boots the smalt
substrate in-lane on the lane-private port block 39420-39425 (lane law
39000+10×42), then drives 1,250 pipeline units × 8 ops = 10,000 storm requests
with 50 concurrent workers (`Task.async_stream`, max_concurrency 50):

- cosmos: PUT doc (POST /docs, pk `p<i>`) + query feed POST
  (`application/query+json`, `SELECT * FROM c`, pk-scoped) — read-your-write
  verified per unit against the query feed response (`id` AND `v` match)
- blob: PUT block (`?comp=block`, 2 KiB) → PUT block list
  (`?comp=blocklist`) → GET blob (byte-exact compare) — block streaming path
- KV: PUT secret + GET secret (value compare)
- AMQP: enqueue per unit; queue drained after the storm with
  dequeue_matching + complete (batch row reported separately)

Plus the drain batch (1,250 dequeue + 1,250 complete = 2,500 ops): 12,500
total measured ops.

## Results (headline)

Storm elapsed: 2,455 ms · headline IOPS **5,091.65** · consistency verdict **PASS**

| op | n | ops/s | p50 ms | p99 ms |
|---|---|---|---|---|
| cosmos_put | 1250 | 509.2 | 38.62 | 132.10 |
| cosmos_query | 1250 | 509.2 | 17.20 | 85.61 |
| blob_stage_block | 1250 | 509.2 | 1.16 | 38.08 |
| blob_commit_block_list | 1250 | 509.2 | 1.48 | 16.47 |
| blob_get | 1250 | 509.2 | 1.06 | 29.91 |
| kv_put | 1250 | 509.2 | 0.37 | 14.36 |
| kv_get | 1250 | 509.2 | 0.37 | 2.70 |
| amqp_enqueue | 1250 | 509.2 | 0.07 | 0.17 |
| amqp_dequeue_complete_batch | 1250 | 3246.4 | 0.28 | 0.72 |

Asserts (all held):

- dropped connections: **0** (any httpc `{:error, _}` counts as dropped)
- read-your-write violations: **0** (every cosmos write followed by a
  pk-scoped query feed read returned the written doc/value; KV + blob value
  compares 100%)
- ETS lock contention ratio: **0.009** (9 of 1,000+ 20ms samples with
  non-empty Store GenServer mailbox; max queue depth 1). Metric definition:
  fraction of 20ms samples where `Smalt.Store`'s mailbox is non-empty — the
  only serialized write path (CAS/next_seq); direct puts are concurrent ETS
  writes with no lock.

## Machine

`{"cpu":"Apple M3 Max","cores":16,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (verbatim machine field from the result rows)

## Commands

```
MIX_BUILD_ROOT=_build-lane502 MIX_ENV=test \
SMALT_TEST_ARM_PORT=39420 SMALT_TEST_EGRESS_PORT=39421 SMALT_TEST_AMQP_PORT=39422 \
SMALT_TEST_EVENT_HUBS_PORT=39423 SMALT_TEST_ARM_TLS_PORT=39424 SMALT_TEST_MCP_PORT=39425 \
mix run --no-start scripts/bench/b42_dataplane_saturation.exs   # exit 0
```

## Artifacts

- `/Users/sac/smalt/docs/jira/v26.10.16/bench/b42-dataplane-saturation.jsonl` (9 rows, lib.sh shape)
- `/Users/sac/smalt/docs/jira/v26.10.16/sdk-results/dataplane-throughput.json` (aggregate)

## Disclosures

1. **AMQP leg is BEAM-tier, not wire**: smalt ships no Elixir AMQP 1.0
   client, so the AMQP ops call `Smalt.Amqp.QueueStore`
   (enqueue/dequeue_matching/complete) in-process against the live substrate.
   The cosmos/blob/KV legs are full wire-level HTTP (`:httpc` → Bandit).
   AMQP wire-tier parity is covered separately by the ts-servicebus SDK
   probes.
2. **Bearer header on every request**: the lane substrate runs
   `auth_mode :anonymous` (config/test.exs), but the KV plane still
   challenges requests with no Authorization header at all
   (egress_router kv challenge), so the driver sends a constant lane bearer
   header. No real token was needed or minted.
3. **cosmos doc create is POST /docs** (PUT /docs/:id is replace-only, real
   Cosmos semantics — PUT of a nonexistent doc 404s).
4. **Latency recorder defect found and fixed in-lane**: ETS bags do not
   store exact duplicate tuples — identical `{op, latency}` pairs from fast
   ops were silently collapsing (kv_put recorded 729/1250 in an early run).
   Fixed with a unique tiebreaker element; final run records n=1250 for
   every op.
5. **Compile-freeze event (other lane's file)**: a mid-run compile broke on
   `lib/smalt/arm_gateway/lro_sweeper.ex` (broken `case` clause from a
   concurrent lane's edit). My minimal-unblock patch did NOT apply (the
   owning lane restored the file first — my edit was a no-op assertion
   failure); the fix in the tree is the owning lane's own.
6. Results jsonl appends across runs; stale rows from two earlier partial
   runs were removed before the final green run (file now holds exactly the
   9 rows of the final run).
