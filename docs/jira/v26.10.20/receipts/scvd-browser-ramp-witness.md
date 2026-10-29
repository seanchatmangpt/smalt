# S14-A — SCVD ramp in-browser witness (t256 + c128 legs in LiveScvd.run/0)

**Standing:** **PASS** (Tier-2/3 latency in-browser: PASS with ~18x margin; memory: PASS, quantized-class, same exposed-surface caveat as S9). Three witnessed runs on the cooked bundle, all exit 0.

## What changed

`popcorn_demo/lib/popcorn_demo/live_scvd.ex` — `run/0` now runs, after the t16 leg:

- `Concurrency.ramp(256)` — all 256 actors `:verified`, zero breaches, else `scvd=FAIL(ramp256:verified-k-of-256-breaches-m)`
- `Concurrency.contention(32)` (gates the leg: a c32 non-determinism FAILs before c128 runs)
- `Concurrency.contention(128)` — Tier-3 rung, its outcome carried in the fragment

Fragment shape (single line, survives the 120-char `Redact.fragment` cap, ~78 chars):

```
scvd=OK(t16:<ms>ms,p99:<us>us;t256:<ms>ms,p99:<us>us;c128:w8/l120/committed8)
```

## Evidence

Pinned toolchain (OTP 29.0.6 / Elixir 1.20.4-otp-29), `MIX_BUILD_ROOT=_build-s14a`. Host-side pre-check:

```
$ mix run -e 'IO.inspect(PopcornDemo.LiveScvd.run())'
{:ok,
 "scvd=OK(t16:7.129ms,p99:7073us;t256:3.313ms,p99:93us;c128:w8/l120/committed8)"}
```

Cook:

```
$ mix popcorn.cook --out-dir public/out
Cooked 8 applications into /Users/sac/smalt/popcorn_demo/public/out/otp/manifest.json
```

In-browser, headless Chromium (chrome-headless-shell 156.0.8078.4), `node scripts/browser_smoke.mjs` x3, all exit 0. scvd fragments, verbatim:

```
run 1: scvd=OK(t16:4.79ms,p99:484us;t256:64.034ms,p99:344us;c128:w8/l120/committed8)
run 2: scvd=OK(t16:4.999ms,p99:505us;t256:64.984ms,p99:310us;c128:w8/l120/committed8)
run 3: scvd=OK(t16:4.884ms,p99:505us;t256:65.185ms,p99:395us;c128:w8/l120/committed8)
```

Memory (runs 2 and 3, `performance.memory` read on the page after the composed receipt, S9's instrumentation; run 1 rode the unmodified shared smoke script):

```
HEAP_RECEIPT: 10000000/10000000 bytes   (runs 2 and 3, identical — Chrome quantization)
```

## Verdicts

| check | target | measured (3 runs) | verdict |
|---|---|---|---|
| Tier-2/3 t256 wall (in-browser) | <1200 ms | 64.034 / 64.984 / 65.185 ms | **PASS** (~18x margin) |
| t256 all-verified, zero breaches | leg law | held every run (fragment is OK-shaped, not FAIL) | **PASS** |
| c128 determinism | 8 winners / 120 losers / 8 committed | `w8/l120/committed8` every run | **PASS** |
| Memory | <32 MB | main-thread JS heap 10,000,000/10,000,000 B (~9.5 MiB) | **PASS**, quantized-class |

Honesty notes:

1. Memory ceiling measured on the exposed main-thread surface only — same
   caveat as S9 (`BENCH_SCVD.md`): the BEAM wasm worker heap and
   `WebAssembly.Memory` committed size are UNMEASURABLE-(exposed-surface).
   The 64 MiB static `WebAssembly.Memory` reservation noted there is virtual
   address space, not committed heap.
2. Full composed lines carried the usual live-leg SKIPs (blob/certs/eg/eh/
   keyops/mcp/policy/queue/tls) — unchanged from prior witnesses, exit 0 per
   the `live=OK` gate law.
3. Host-vs-browser divergence is real and now measured on both sides:
   host t256 ~3.3 ms (JIT) vs wasm t256 ~65 ms — 20x, well inside budget.
