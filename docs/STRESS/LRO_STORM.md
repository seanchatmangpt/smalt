# LRO Storm — Stress Receipt

Real-wire LRO stress of the smalt ARM gateway. Driver:
`scripts/stress/lro_storm.py`. Run 2026-10-14, `smalt` @ tree state
2026-10-14 (uncommitted shared tree, concurrent lanes active), macOS / OTP 28.3.1 /
Elixir 1.19.5.

## Run

```bash
python3 scripts/stress/lro_storm.py
```

Boots a real smalt substrate (`mix run --no-start -e` boot: all listeners on
runtime-free ports — concurrent smalt lanes race for the defaults), drives it
over real HTTP/1.1 keep-alive sockets, and introspects the live node via a
distributed-erlang probe (`:erpc` into the server node: beam `process_count`
+ `:ets.info(:smalt_operations, :size)`).

## Phases (all PASS, 21/21 checks)

### Phase 1 — 1,000 concurrent LRO PUTs

1000/1000 storageAccount PUTs returned **202** with `Azure-AsyncOperation` op
ids; `:smalt_operations` went **0 -> 1000** exactly (+1000 expected).

Polling all 1000 ops in waves of 250 — every op Succeeded on first poll:

| wave (backlog) | p50 | p95 | max (ms) |
|---|---|---|---|
| wave@0 | 9.3 | 16.9 | 22.1 |
| wave@250 | 5.6 | 10.2 | 16.8 |
| wave@500 | 5.0 | 10.3 | 15.1 |
| wave@750 | 7.1 | 12.3 | 14.7 |

Poll latency is flat across backlog waves (p95 9-17 ms from a 1000-thread
Python client; the client, not the server, is the bottleneck). Confirms the
store-record lazy model is O(1) per poll — no timers, no per-op processes.

### Phase 2 — 100 long ops (30 s delay) + interleaved GETs

`:lro_delay_ms` set to 30000 live via `:erpc`; 100/100 PUTs → 202, immediate
polls all 202 InProgress. While the 30 s delay elapses, 281,896 interleaved
resource GETs: **281,896/281,896 returned 200**, p95 1.8 ms vs baseline p95
5.6 ms (threshold 250 ms) — no latency bleed. All 100 long ops flipped to
Succeeded lazily on poll (no timers, no process-lifetime coupling).

### Phase 3 — delete-created-resource sweep

1000/1000 DELETEs → 200; 50/50 deleted-resource GETs → 404;
50/50 op records still queryable (200 Succeeded); `:smalt_operations`
after sweep = **1100** (>= 1100: 1000 + 100, records persist after resource
deletion).

### Process count (no unbounded spawn)

| sample | beam process_count |
|---|---|
| before | 1166 |
| peak (1 s sampling through storm) | 1235 |
| after | 1166 |

after == before; peak drift +69 transient (request-handling processes only).

## Falsifiers (all failed to refute)

- a 202 rate < 100% → 1000/1000
- op-table growth != +N PUTs → 0 -> 1000 exactly
- any op not Succeeded on first poll → all Succeeded
- poll latency growing with backlog → flat
- GET p95 under LRO load > 250 ms or > 5x baseline → 1.8 ms
- any interleaved GET non-200 → 281896/281896
- deleted resource GET != 404 → 50/50 404
- op record unrecoverable after resource deletion → 50/50 queryable
- process_count after >> before → 1166 == 1166

## Environment notes (receipt-relevant)

- Server boot retries tolerate shared-tree compile freezes (concurrent lanes
  editing `lib/` mid-run; two freezes were ridden out during development:
  `egress_router.ex`, `amqp/queue_store.ex`, both fixed by their owners).
- All listeners on runtime-free ports — AMQP 5672 was held by another lane's
  broker during this window.
- Client is single-process Python threads; server-side latencies are lower
  than reported. Client-supplied latencies are upper bounds.
- Driver validates the wire-contract details it depends on (bearer-token STS
  issuance, `Azure-AsyncOperation` header, `Retry-After`, ARM 404 envelope,
  GraphLaw shape validation) — these are the real client obligations.
