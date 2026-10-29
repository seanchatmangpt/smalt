# PB-3 — Executor concurrency ceiling (OTP-29)

Context: solo
**Standing:** PASS

- **Date**: 2026-10-21
- **Subject**: `lib/smalt/powl2/executor.ex` @ main (e626924)
- **Lane**: PB-3, executor-concurrency menu item 3 (in-process face, no socket)
- **Script**: `/Users/sac/smalt/scripts/bench/pb3_executor_ceiling.exs` — run as `mix run --no-start scripts/bench/pb3_executor_ceiling.exs` under Elixir 1.20.4-otp-29 (`--no-start` because the shared substrate holds the data-plane ports and the executor kernel needs no booted app; real DETS table opened in-process)
- **Toolchain**: Elixir 1.20.4-otp-29 / Erlang/OTP 29.1.2 (erts-17.1.1)
- **Machine**: Apple M3 Max, 16 cores, Darwin 26.2

## Method

N independent 4-step settlement orchestration instances (linear PartialOrder
`debit → hold → capture → settle`, real DETS persistence under
`{:powl2_receipt, id}`), all through `Smalt.POWL2.Executor.execute_admitted/6`
Task-based frontier parallelism. Ramp N = 64 → 8192, escalated past the
dispatched 2048 while errors = 0 (T3 wall methodology: typed wall_level at
first error cliff). No cliff occurred.

## Command output (verbatim, final run)

```
N=64 wall_ms=3 errors=0 p50=2 p95=3 p99=3 lat_count=64
N=256 wall_ms=11 errors=0 p50=7 p95=10 p99=10 lat_count=256
N=512 wall_ms=21 errors=0 p50=14 p95=15 p99=15 lat_count=512
N=1024 wall_ms=45 errors=0 p50=22 p95=25 p99=25 lat_count=1024
N=2048 wall_ms=155 errors=0 p50=60 p95=82 p99=83 lat_count=2048
N=4096 wall_ms=555 errors=0 p50=76 p95=259 p99=263 lat_count=4096
N=8192 wall_ms=2176 errors=0 p50=203 p95=224 p99=226 lat_count=8192
wrote /Users/sac/smalt/tmp/bench/pb3-executor-ceiling.jsonl
wall_level=unreached-at-8192 total_errors=0
```

## Results (ground truth: /Users/sac/smalt/tmp/bench/pb3-executor-ceiling.jsonl)

| N | wall_ms | ops/s | p50_ms | p95_ms | p99_ms | errors | wall_level |
|---|---|---|---|---|---|---|---|
| 64 | 3 | 21,333 | 2 | 3 | 3 | 0 | unreached |
| 256 | 11 | 23,273 | 7 | 10 | 10 | 0 | unreached |
| 512 | 21 | 24,381 | 14 | 15 | 15 | 0 | unreached |
| 1024 | 45 | 22,756 | 22 | 25 | 25 | 0 | unreached |
| 2048 | 155 | 13,213 | 60 | 82 | 83 | 0 | unreached |
| 4096 | 555 | 7,380 | 76 | 259 | 263 | 0 | unreached |
| 8192 | 2176 | 3,765 | 203 | 224 | 226 | 0 | unreached |

Summary row: `wall_level = unreached-at-8192`, total errors 0.

## Verdict

- **0 errors across the full ramp, L64 → L8192.** The in-process face has no
  socket bound and **the wall was not reached at N=8192** —
  `unreached-at-8192`, i.e. still clean 2x past the wire face's clean ceiling.
- **vs the wire wall (T3, `tmp/bench/scvd-tier3.jsonl`,
  `receipts/scvd-wave-summary.md`)**: the wire face is clean through L4096 and
  types its wall at L8192 (534 errors, `typed_fail_512`). The in-process
  executor face is still error-free at the level where the wire face already
  walls — the wall's locus is the socket/handshake layer, not the
  orchestration kernel.
- **Honest decay claim**: beyond ~L2048 the executor is slow but never wrong —
  ops/s falls 22.8k@1024 → 3.8k@8192 and per-instance latency plateaus at
  ~200–240 ms (scheduler-queueing saturation, typed as *slow*, not as errors).
  No untyped collapse, no DETS failures, no refused orchestrations.
- **Wall claim**: the executor's actual ceiling lies above L8192 and was
  **not reached**; escalation stopped at 8192 (2x the wire's clean line) with
  errors=0 at every rung.

## Standing

**PARTIAL_ALIVE** — the executed claim (0 errors L64→L8192, wall
unreached-at-8192) is receipted on this subject; the executor's true wall
above L8192 remains UNKNOWN.

## Reproduction (2026-10-21 backfill, fresh full re-run)

```text
$ export PATH=~/.asdf/installs/erlang/29.1.2/bin:~/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
$ MIX_BUILD_ROOT=_build-ctxfill MIX_ENV=test mix run --no-start scripts/bench/pb3_executor_ceiling.exs
N=64 wall_ms=5 errors=0 p50=5 p95=5 p99=5 lat_count=64
N=256 wall_ms=11 errors=0 p50=8 p95=10 p99=10 lat_count=256
N=512 wall_ms=22 errors=0 p50=16 p95=18 p99=18 lat_count=512
N=1024 wall_ms=53 errors=0 p50=27 p95=31 p99=31 lat_count=1024
N=2048 wall_ms=165 errors=0 p50=52 p95=58 p99=59 lat_count=2048
N=4096 wall_ms=652 errors=0 p50=141 p95=157 p99=157 lat_count=4096
N=8192 wall_ms=2599 errors=0 p50=264 p95=351 p99=355 lat_count=8192
wrote /Users/sac/smalt/tmp/bench/pb3-executor-ceiling.jsonl
wall_level=unreached-at-8192 total_errors=0
exit 0
```

Fresh run reproduces the claim: 0 errors L64→L8192, wall unreached-at-8192
(fresh jsonl rows overwrote tmp/bench/pb3-executor-ceiling.jsonl, same shape).
