# PB-1 — FOND contingency-loop latency: native POWL2 vs SDK-over-HTTP under injected CAS contention

**Standing: PARTIAL_ALIVE** — native leg fully executed (contention 0→100%, 0→10 forced
strong-cyclic retries/settlement, 0 errors); SDK leg executed but its contention
injection is IMPOSSIBLE on this substrate: the cosmos HTTP surface ignores `If-Match`
(1700/1700 injected stale etags accepted, 0 412s) — see DIV-1. All numbers below are
measured; nothing is projected.

- Date: 2026-10-21 · Lane: PB-1 (port block 39010..39015, atls=39014) · Context: full
- Result file: `/Users/sac/smalt/tmp/bench/pb1-fond-sweep.jsonl` (22 rows, bench_emit schema
  + `contention_pct`/`retries_forced`, SDK rows carry `injection_failures`)
- Scripts: `/Users/sac/smalt/scripts/bench/pb1_fond_sweep.sh` (driver),
  `pb1_fond_sweep.exs` (native), `pb1_cosmos_sdk.mjs` (SDK)
- Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}`

## Method

- **Native leg**: `Smalt.POWL2.Executor` executes a PartialOrder of 4 concurrent
  `Transition`s; each op settles one doc via `Smalt.POWL2.ChangeFeed` CAS: R forced
  stale-etag attempts (412, recover etag via read) then one match (200).
  150 timed waves + 20 warmup per rate, R = 0..10, µs-resolution monotonic clock.
- **SDK leg**: real `@azure/cosmos` 4.10.1 (verification/ts), `https://127.0.0.1:39014`
  (the 9444 twin seat; cert `tmp/dev-certs/dev-cert-39014.pem` — the bench twin runs TLS
  `:auto` self-signed per-seat, NOT the `.smalt/tls` dev CA chain), DEFAULT retry options
  (429 throttle backoff active), 4 concurrent settlements per orchestration, same
  injection shape. Loud-SKIP guard ran (probe of egress /dbs; would exit 3 if down).
- Both legs: 4-doc fanout per orchestration, identical injection loop shape.

## Results — wall per orchestration (ms)

| retries | cont% | nat p50 | nat p95 | nat p99 | nat ops/s | sdk p50 | sdk p95 | sdk p99 | sdk ops/s | inj-fail |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 0% | 0.033 | 0.072 | 0.121 | 25239.78 | 5.829 | 9.025 | 11.510 | 165.19 | 0 |
| 1 | 10% | 0.043 | 0.093 | 0.157 | 19152.2 | 3.576 | 17.824 | 48.342 | 179.64 | 170 |
| 2 | 20% | 0.047 | 0.100 | 0.118 | 18353.11 | 3.827 | 7.207 | 12.504 | 234.27 | 170 |
| 3 | 30% | 0.053 | 0.113 | 0.140 | 16142.92 | 4.664 | 9.296 | 24.975 | 191.58 | 170 |
| 4 | 40% | 0.065 | 0.135 | 0.188 | 12733.45 | 4.268 | 11.152 | 15.576 | 195.28 | 170 |
| 5 | 50% | 0.079 | 0.145 | 0.172 | 11286.68 | 4.314 | 13.381 | 31.177 | 179.49 | 170 |
| 6 | 60% | 0.078 | 0.147 | 0.157 | 11432.93 | 5.154 | 20.743 | 71.149 | 123.4 | 170 |
| 7 | 70% | 0.094 | 0.165 | 0.241 | 9779.63 | 3.781 | 8.045 | 12.249 | 232.87 | 170 |
| 8 | 80% | 0.110 | 0.190 | 0.234 | 8451.18 | 4.112 | 7.181 | 9.623 | 227.01 | 170 |
| 9 | 90% | 0.121 | 0.209 | 0.270 | 7630.09 | 4.469 | 9.048 | 15.272 | 198.89 | 170 |
| 10 | 100% | 0.150 | 0.240 | 0.299 | 6528.55 | 4.952 | 11.534 | 30.299 | 158.26 | 170 |

(Table generated directly from tmp/bench/pb1-fond-sweep.jsonl — no hand transcription.)

## Measured deltas (computed from the jsonl, not the table)

- **Native per-retry tax (the loop's own cost)**: p50 0.033→0.150 ms across r0→r10 ⇒
  **0.0117 ms/retry (~11.7 µs)** marginal CAS-retry cost; p95 0.072→0.240 ms; throughput
  25.2k→6.5k ops/s (3.9× decay, monotone in R). No backoff — the loopback is a same-beam
  gen_statem re-entry, zero sleep, zero network.
- **SDK wall is flat in R because contention never happened (DIV-1)**: p50 5.8→5.0 ms,
  statistically flat; ops/s 165→158 (noise). The measured -0.088 ms/"retry" slope is
  negative noise, NOT a backoff tax — 1700/1700 stale etags were accepted with 200, zero
  412s observed, so the SDK's 412-facing path never engaged. Its 429 throttle backoff also
  never fired (0 429s emitted by the surface at this load). **SDK retry-backoff tax:
  NOT MEASURABLE on this substrate.**
- **Surface tax (native r0 vs SDK r0, the honest same-work comparison)**: 0.033 vs 5.829 ms
  p50 = **176× HTTP/TLS-SDK-overhead tax** at zero contention; ops/s 25239.8 vs 165.2.

## DIV-1 — cosmos HTTP surface ignores If-Match (open divergence, needs a KD row)

Witness: private anonymous bench substrate (lane b1, 39014 twin seat), real SDK probe:
create → replace with `ifMatchEtag: "totally-bogus-etag"` → **200**, etag rotated, then
CAS-match replace → 200. Also 1700/1700 injected stale etags accepted across the sweep.
`lib/smalt/egress/CosmosRoutes.ex` handles `if-none-match` (304) but has no `if-match`
/412 path. Close condition: stale `ifMatchEtag` replace returns 412 with the current etag;
rerun the SDK contention leg and measure the true SDK backoff tax. I did not mint a KD-nn
row (registrar owns the register); this receipt is the evidence receipt to attach.

## Commands (replay)

```bash
cd /Users/sac/smalt
bash scripts/bench/pb1_fond_sweep.sh   # boots lane b1 substrate, both legs, emits jsonl
```

Context: full. Honest-failure disclosure: SDK leg errors field is 0 only because injected
contention silently succeeded; the injection_failures=170/rate column IS the failure count.
