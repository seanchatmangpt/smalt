# N-1 Grid Lifecycle Stress Receipt

- Lane: N-1 (workspace grid bench), v26.10.14
- Date: 2026-10-15
- Subject: `/Users/sac/smalt` @ main `518b31a` (uncommitted lane tree)
- Page: `workspace/app/bench/grid/page.tsx` (10,000-row virtualized grid, hierarchical rollups, TreeNavigator-pattern windowing, 28px rows, overscan 10, deterministic mulberry32(0x5eed) fixture shared server/client)
- Driver: `scripts/bench/n1_grid.spec.mjs` (Playwright chromium headless + CDP)
- JSONL: `docs/jira/v26.10.14/bench/n1-grid.jsonl` (13 rows, this run)
- Trace: `/tmp/n1-grid-trace.json` (32.9 MB, DrawFrame analysis)

## Scenario

SSR init -> hydration -> 30s mutation burst (programmatic scroll ~100 rows/s
via rAF scrollTop driver + 50 patch events/s injected through the page's own
`setRows` state setter via `window.__bench.applyPatches`, each patch mutating
a leaf and propagating into its subgroup + group rollups).

## Falsifier verdict: PASS

Frame-drop rate 0% (threshold 5%), detached-node leak 0 (threshold 500).

## Consolidated table row

| scenario | ttfb_ms | hydration_ms | drop_rate | detached_nodes | heap_delta_mb | long_tasks | verdict |
|---|---|---|---|---|---|---|---|
| n1 | 3.55 | 61.5 | 0.00 | 0 | 0.88 | 0 | **PASS** |

## Measurements (13 JSONL rows, {scenario,metric,value,threshold,status})

| metric | value | threshold | status |
|---|---|---|---|
| ttfb_ms (CDP Network doc request->response) | 3.55 ms | info | INFO |
| hydration_ms (performance.mark smalt-bench:hydrated) | 61.5 ms | info | INFO |
| draw_frames (CDP Tracing DrawFrame, 30s) | 1849 vs 1800 expected @60Hz | >=1710 | PASS |
| frame_drop_rate (1 - drawn/expected) | 0.00 | <=0.05 | PASS |
| raf_drop_rate (in-page rAF cross-check) | 0.00 | <=0.05 | PASS |
| detached_nodes_leak (CDP Performance Nodes delta after forced GC) | 0 | <=500 | PASS |
| dom_churn added/removed (MutationObserver) | 3030/3030 | info | INFO |
| js_event_listener_delta (GC'd) | 0 | <=50 | PASS |
| heap_delta (JSHeapUsedSize after GC) | 0.88 MB | <=50 | PASS |
| long_task_count / total | 0 / 0 ms | info | INFO |
| patches_applied (1500 target) | 1492 | >=1350 | PASS |

## Methods

- Frames: CDP `Tracing.start` (devtools.timeline + frame category), DrawFrame
  events counted; cross-checked with in-page rAF tick sampling. Both at 0%
  drops (1849 drawn > 1800 expected; rAF 1800/1800).
- Detached DOM: `Performance.getMetrics` `Nodes` before/after burst with
  `HeapProfiler.collectGarbage` before each read -> retained-node delta 0.
  Churn observer confirms windowing replaced ~3030 rows without retention.
- Heap: `JSHeapUsedSize` delta after GC = 0.88 MB (units: CDP reports bytes;
  first run's 928,636 "MB" was a driver unit bug, fixed and re-run).
- Patches: 1492/1500 applied (driver timer skew under burst, within 90% gate).

## Environmental receipts

- `next build` EXIT=0 (`/bench/grid` static prerendered, route table in
  `/tmp/n1_build2.log`); `next start -p 3311`, curl 200, TTFB 20ms cold.
- Setup idempotent: playwright 26.10.0 + chromium already in
  `workspace/node_modules` / `~/Library/Caches/ms-playwright`;
  `npm i -D playwright` added the devDep entry to `workspace/package.json`.

## Cross-lane disclosures (compile-freeze SLA minimal unblock fixes)

Shared `next build` was blocked by three other lanes' type errors; I applied
minimal fixes, each disclosed:
1. `workspace/app/bench/action/page.tsx` — `revalidateTag(tag)` -> `revalidateTag(tag, "max")` (Next 16 two-arg signature).
2. `workspace/app/bench/metrics/route.ts` — `type IntervalHistogram` not exported by the local node types; replaced with `ReturnType<typeof monitorEventLoopDelay>`.
3. `workspace/lib/bench/topo-worker.ts` — module-scope `const self` redeclared global `self`; renamed `workerSelf` (refs updated).
The N-3 compute lane's mid-edit parse error resolved itself on their next save
(no fix from me survived for that file).

## Teardown

next start killed (pid from `/tmp/n1_next.pid`), port 3311 confirmed down.
No commits made; no lib/ edits. Trace left at `/tmp/n1-grid-trace.json`
(32.9 MB) for DrawFrame inspection.
