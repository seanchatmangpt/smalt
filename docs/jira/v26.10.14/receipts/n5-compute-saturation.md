# Receipt — N-5 Compute Saturation (workspace Next.js lifecycle bench)

- Lane: N-5, v26.10.14, canonical checkout `/Users/sac/smalt`
- Date: 2026-10-15
- Subject identity:
  - `workspace/app/bench/compute/page.tsx` (client page, rAF FPS counter, tab/chart
    surface, input-latency probe, driver bridge `window.__n5`)
  - `workspace/lib/bench/topo-worker.ts` (dedicated worker: Kahn topological sort
    over a generated 50k-node DAG, 15 s compute, plain JS — Wasm-free)
  - `scripts/bench/n5_compute.spec.mjs` (Playwright 1.64 + CDP driver)
  - `docs/jira/v26.10.14/bench/n5-compute.jsonl` (result rows, final valid run)
- Server: `next build` + `next start -p 39055` (production, not dev)
- Browser: Playwright chromium headless,
  `--enable-precise-memory-info --js-flags=--expose-gc`

## Subject

/bench/compute boots, generates a deterministic 50 MB DAG edge list (xorshift32,
edges constrained `from < to` = acyclic by construction), spawns the worker, and
transfers the 50 MB ArrayBuffer zero-copy (`postMessage` transfer list; main-thread
copy detached). The worker runs Kahn topological sort (CSR adjacency + FIFO) for
15 s continuously over the transferred buffer while the driver injects 60 Hz mouse
input over CDP and the main thread renders a chart/tab surface with an FPS counter.

## Measurement method (honest, per instrument)

| Metric | Instrument | Note |
|---|---|---|
| Input latency | page `__n5.arm()` stamp -> CDP `Input.dispatchMouseEvent` -> capture listener -> next rAF delta | driver-injected input, page-measured paint |
| Dropped frames | in-page rAF accounting: frame gap >20 ms = dropped (60 Hz = 16.6 ms budget) | CDP Tracing frame parse rejected as over-complex; rAF counter is the witness |
| Worker memory | worker posts computed typed-array allocations (edge buffer 50 MB + CSR adj + indeg + queue) inline in the compute loop | `performance.memory` does not exist in workers, and a 100%-busy worker never turns its event loop so `setInterval` never fires — first run's -1 sentinels invalidated run 1; superseded |
| Reclaim | `worker.terminate()` -> forced `window.gc()` each poll, heap back within 5% of baseline within 5 s; CDP `Target.getTargets` worker count -> 0 | forced GC separates RETENTION from GC scheduling lag |

## Results (final valid run, 2026-10-15)

| Metric | Value | Budget | Verdict |
|---|---|---|---|
| Worker liveness (topo iterations in 15 s) | 298 iterations (~296 ms/iter over 6.25 M edges) | > 0 | PASS |
| Interaction events (60 Hz) | 888 dispatched | — | — |
| Frames during interaction | 918 over 15 s = 61.2 fps | — | — |
| Dropped frames | 0 / 918 = 0.00% | ≤ 5% | PASS |
| Input latency p50 / p95 / p99 / max | 8.9 / 15.2 / 16.0 / 17.6 ms | sustained ≤ 16.6 ms | PASS (0.45% of samples over budget; not sustained) |
| Worker peak allocation | 79,443,224 B (~75.8 MiB: 50 MB buffer + CSR + queue) | — | — |
| Reclaim post-terminate | heap 7,653,226 -> 3,922,630 B vs baseline 3,980,633 B (within 5%) in < 5 s, 1 forced GC; CDP workers 1 -> 0 | within 5% in 5 s | PASS |
| Memory-reclaim falsifier | — | — | PASS |

Falsifier verdicts:
1. Sustained input latency >16.6 ms OR dropped frames >5%: **PASS (not falsified)** —
   p95 15.2 ms, 0 dropped frames, 0.45% samples over budget.
2. Worker/wasm memory not reclaimed post-termination: **PASS (not falsified)** —
   heap back under baseline after 1 forced GC; worker target count 0.

## Wasm status (honest note)

Wasm: **PENDING**. Plain JS only. The AtomVM sim mode ships no wasm `.avm`
artifact, and no wasm toolchain output is wired into this worker as of
v26.10.14. No wasm claim is made.

## Caveats / limits

- One run of record after an invalidated first run (dead worker-memory
  instrumentation). Falsifiers are per-run, not statistical.
- Input latency measured from CDP dispatch to next rAF — includes CDP transport
  jitter; still under budget at p95.
- `performance.memory` values are Chromium-quantized even with precise-memory-info;
  reclaim verdict tolerates this via the 5% band.
- Frames during interaction: 918 frames / 15 s = 61.2 fps.

## Files owned/touched

- `workspace/app/bench/compute/page.tsx` (new)
- `workspace/lib/bench/topo-worker.ts` (new)
- `scripts/bench/n5_compute.spec.mjs` (new)
- `docs/jira/v26.10.14/bench/n5-compute.jsonl` (new, 4 rows)
- `docs/jira/v26.10.14/receipts/n5-compute-saturation.md` (this file)

## Cross-lane disclosure (compile-freeze SLA)

Lane N-2's files (`app/bench/action/page.tsx`, `app/bench/metrics/route.ts`)
blocked the shared `next build` early in the session; both lanes self-repaired
their files before I applied any fix — no cross-lane edits were ultimately made
by N-5. `lib/bench/topo-worker.ts` received an out-of-session edit (a
`workerSelf` alias) which was retained and integrated, not reverted.
