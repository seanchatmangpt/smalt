# APEX-4 — "tollbooth vs silicon" rate-limit falsifier

**Standing:** **ALIVE** — both arms executed on real BEAM concurrency, zero errors,
Chicago bucket check PASS, deterministic-seed reproducibility witnessed (2 runs,
ratio 692x / 707x).

## What ran

`MIX_BUILD_ROOT=_build-apex4 mix run -e 'PopcornDemo.ApexRatelimit.run()'`
(lane build root `_build-apex4`; executed via direct `elixir -pa` on the lane's
compiled beams because a sibling lane's `apex_fanout.ex` was mid-edit and
not compiling during this window — compile-freeze disclosure: this lane did
NOT touch that file, it routed around it per the SLA).

Module: `popcorn_demo/lib/popcorn_demo/apex_ratelimit.ex`
Result file (this lane's ONLY result file):
`popcorn_demo/bench/apex_ratelimit.jsonl`

## Design

- **Arm 1 (silicon)**: 1,024 concurrent `Task` actors each perform one
  increment of a shared `:atomics` counter via a CAS retry loop
  (`compare_exchange`). No sleeps anywhere in this arm. Winner/loser
  distribution = winners (1,024 grants) vs total CAS attempts; retries_total
  = attempts − winners.
- **Arm 2 (simulated Azure)**: the SAME 1,024 CAS ops, each gated by a
  single-atomic-word token bucket (capacity 100 RU, refill 100 RU/s; word =
  `ms <<< 16 + tokens_x100`, one CAS covers refill+take so racing takers
  cannot double-apply refill or go negative). Over-demand answers typed
  `{:throttled, retry_after_ms}` (429) and the client applies Cosmos
  documented-default exponential backoff: 9 retries, 30s ceiling,
  50ms base ×2^attempt ±20% jitter (seed `:exsss {1, 942042, 314159}`).
  The single wait site carries `# SLEEP-CLASS: TIME-ADVANCE` — those sleeps
  ARE the simulated cost being measured.
- **Chicago check** (`verify_bucket/0`, ran 4x green during the lane, 1x as
  run/0 preflight): real bucket, final-state asserts — over-capacity burst
  meets ONLY typed integer-hinted 429s; refused > 0 (limit enforced); granted
  < demand; token balance never negative; bounded poll on `peek/1` proves
  refill restores full capacity; refilled bucket re-enforces (10 grants then
  typed refusal).

## Measured table (run 2, on disk in apex_ratelimit.jsonl)

Machine: `just bench-machine` →
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
(lane ran on elixir 1.20.3-otp-28 per the directed host toolchain; row machine
fields report the running runtime).

| metric | arm 1: local CAS (silicon) | arm 2: simulated 429 (tollbooth) |
|---|---|---|
| n | 1024 | 1024 |
| wall | **20 ms** | **14,138 ms** |
| ops/sec | 51,200 | 72.4 |
| p50 / p95 / p99 (ms) | 0 / 0 / 0 | 56 / 464 / 2871 |
| retries total | 0 CAS retry loops | 1,150 backoff retries (429s) |
| ops ever throttled | 0 | 713 / 1024 |
| retries exhausted | 0 | 0 |
| errors | 0 | 0 |

Run 1 (same seed): local wall 15ms (1 CAS retry), sim wall 10,375ms,
ratio **691.7x**; throttled_ops 771. Consistent within jitter.

## Typed verdict

**local wall 20 ms vs simulated-throttled wall 14,138 ms — ratio ~707x**
(run 1: 15ms vs 10,375ms, 692x). Honest-modeling note: the simulated arm
models the DOCUMENTED Cosmos backoff behavior (9 retries / 30s ceiling) and a
locally-parameterized token bucket — it is not a live Azure run; the measured
delta bounds the coordination cost of a remote RU-metered plane versus local
in-memory arbitration on this machine, which is exactly the falsifier's claim.

## Typed findings

- The tollbooth is the cost: local CAS contention over 1,024 actors costs
  sub-millisecond (p99 0ms; at most 1 hardware-CAS retry across two runs).
  The entire ~700x delta is the RU meter + backoff curve.
- Deterministic seed makes the backoff curve reproducible; throttled-op count
  varies with scheduler interleaving (713 vs 771), retries never exhausted.
- Known pitfall fixed in-module: BEAM `monotonic_time` is negative on this
  host, and `div/rem` packing corrupted the token field — replaced with
  sign-correct arithmetic-shift packing (`pack/unpack`).

## Receipts

- Result: `popcorn_demo/bench/apex_ratelimit.jsonl` (2 rows, lane apex4)
- Module: `popcorn_demo/lib/popcorn_demo/apex_ratelimit.ex`
- Chicago check source: `PopcornDemo.ApexRatelimit.verify_bucket/0`
