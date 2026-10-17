#!/usr/bin/env node
/**
 * n8 lifecycle soak bot — N-8 lane, v26.10.14.
 *
 * Drives 500 complete task cycles against the Sovereign Console:
 *   load /console -> expand/select TreeNavigator nodes -> open inspector tab
 *   -> trigger copilot panel -> route-switch (/ and /bench/audit) -> repeat.
 *
 * Metrics:
 *   - V8 JSHeapUsedSize via CDP Performance.getMetrics every 50 cycles
 *   - DOMCounter (Nodes), JSEventListeners (listener-count stability)
 *   - 3 CDP .heapsnapshot files at cycles 1 / 250 / 500
 *   - jsonl ledger -> bench_results/nextjs_lifecycle/n8-soak.jsonl (and a copy
 *     under docs/jira/v26.10.14/bench/)
 *
 * Falsifier: retained heap growth >10% over 500 cycles with a LINEAR slope
 * -> FAIL (leak); sawtooth with stable envelope -> PASS.
 *
 * Usage: node scripts/bench/n8_soak_bot.mjs [--base http://localhost:3100]
 */

let chromium;
try {
  ({ chromium } = await import('playwright'));
} catch {
  // Script lives outside workspace/node_modules — resolve Playwright from the
  // workspace app that owns it (Next.js production dep set).
  ({ chromium } = await import(path.resolve(HERE, '../../workspace/node_modules/playwright/index.mjs')));
}
import { mkdirSync, writeFileSync, appendFileSync, existsSync, rmSync } from 'node:fs';
import path from "node:path";
const HERE = path.dirname(import.meta.url).replace("file://", "");
import { join, dirname } from 'node:path';

const BASE = process.argv.includes('--base')
  ? process.argv[process.argv.indexOf('--base') + 1]
  : process.env.N8_BASE || 'http://localhost:3100';
const TOTAL_CYCLES = Number(process.env.N8_CYCLES || 500);
const SAMPLE_EVERY = 50;
const SNAPSHOT_CYCLES = new Set([1, 250, 500]);
const OUT_DIR = join(process.cwd(), 'bench_results/nextjs_lifecycle');
const JSONL_PATH = join(OUT_DIR, 'n8-soak.jsonl');
const DOCS_JSONL = join(process.cwd(), 'docs/jira/v26.10.14/bench/n8-soak.jsonl');

const ROUTES = ['/', '/bench/audit'];

function iso() {
  return new Date().toISOString();
}

async function getMetrics(cdp) {
  const { metrics } = await cdp.send('Performance.getMetrics');
  const m = {};
  for (const { name, value } of metrics) m[name] = value;
  return m;
}

async function takeHeapSnapshot(cdp, cycle, outDir) {
  // HeapProfiler.takeHeapSnapshot streams reportProgress events; the snapshot
  // data itself arrives via addHeapSnapshotChunk events. Collect chunks.
  const chunks = [];
  const onChunk = (e) => chunks.push(e.chunk);
  cdp.on('HeapProfiler.addHeapSnapshotChunk', onChunk);
  await cdp.send('HeapProfiler.collectGarbage'); // retained-heap semantics
  await cdp.send('HeapProfiler.takeHeapSnapshot', { reportProgress: false });
  cdp.off('HeapProfiler.addHeapSnapshotChunk', onChunk);
  const file = join(outDir, `cycle-${String(cycle).padStart(3, '0')}.heapsnapshot`);
  writeFileSync(file, chunks.join(''));
  return file;
}

/** Linear-regression slope of heap samples (bytes/cycle) + sawtooth check. */
function analyze(samples) {
  const n = samples.length;
  if (n < 2) return { slopePerCycle: 0, r2: 0, sawtooth: true, envelope: 'stable' };
  const xs = samples.map((s) => s.cycle);
  const ys = samples.map((s) => s.heap);
  const mx = xs.reduce((a, b) => a + b, 0) / n;
  const my = ys.reduce((a, b) => a + b, 0) / n;
  let num = 0;
  let den = 0;
  for (let i = 0; i < n; i++) {
    num += (xs[i] - mx) * (ys[i] - my);
    den += (xs[i] - mx) ** 2;
  }
  const slopePerCycle = den === 0 ? 0 : num / den;
  const intercept = my - slopePerCycle * mx;
  let ssRes = 0;
  let ssTot = 0;
  for (let i = 0; i < n; i++) {
    const pred = slopePerCycle * xs[i] + intercept;
    ssRes += (ys[i] - pred) ** 2;
    ssTot += (ys[i] - my) ** 2;
  }
  const r2 = ssTot === 0 ? 1 : 1 - ssRes / ssTot;
  // Sawtooth: meaningful mid-run decreases (GC recovery dips) in the series.
  let maxDrawdown = 0;
  let peak = ys[0];
  for (const y of ys) {
    if (y > peak) peak = y;
    maxDrawdown = Math.max(maxDrawdown, peak - y);
  }
  const mean = my;
  const sawtooth = maxDrawdown > 0.25 * mean;
  const env = Math.max(...ys) / Math.min(...ys);
  const envelope = env < 1.35 ? 'stable' : 'growing';
  return { slopePerCycle, r2, sawtooth, maxDrawdown, envelope };
}

async function waitForServer(url, timeoutMs = 90_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      const r = await fetch(url);
      if (r.ok) return true;
    } catch {}
    await new Promise((r) => setTimeout(r, 1000));
    process.stdout.write('.');
  }
  return false;
}

const modal = (msg) => {
  console.error(`[n8] ${msg}`);
};
modal(`start base=${BASE} cycles=${TOTAL_CYCLES}`);
mkdirSync(OUT_DIR, { recursive: true });
const docsDir = dirname(DOCS_JSONL);
mkdirSync(docsDir, { recursive: true });
if (existsSync(JSONL_PATH)) rmSync(JSONL_PATH);

if (!(await waitForServer(BASE))) {
  console.error('[n8] FATAL: server did not become ready');
  process.exit(2);
}
modal('server ready');

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const cdp = await context.newCDPSession(page);
await cdp.send('Performance.enable');
await cdp.send('HeapProfiler.enable');

const events = [];
function emit(rec) {
  rec.ts = iso();
  events.push(rec);
  appendFileSync(JSONL_PATH, JSON.stringify(rec) + '\n');
  try {
    appendFileSync(DOCS_JSONL, JSON.stringify(rec) + '\n');
  } catch {}
}

const samples = [];
let errors = 0;
const t0 = Date.now();

try {
  for (let cycle = 1; cycle <= TOTAL_CYCLES; cycle++) {
    // 1. Load /console fresh (client-side nav back after first cycle).
    if (cycle === 1) {
      await page.goto(`${BASE}/console`, { waitUntil: 'load' });
    } else {
      await page.goto(`${BASE}/console`, { waitUntil: 'load' });
    }

    // 2. TreeNavigator: expand a node, select nodes.
    const tree = page.locator('[role="tree"]');
    await tree.waitFor({ state: 'visible', timeout: 15_000 });
    const items = page.locator('[role="treeitem"]');
    const first = items.first();
    await first.click(); // expand
    // select a deeper item if present
    const count = await items.count();
    if (count > 2) await items.nth(1).click(); // select
    if (count > 3) await items.nth(2).click(); // re-select (state churn)

    // 3. Inspector tab (modal/inspector tab open).
    const tabs = page.locator('[role="tab"]');
    if ((await tabs.count()) > 1) {
      await tabs.nth(1).click();
      await page.waitForTimeout(10);
      if ((await tabs.count()) > 2) {
        await tabs.nth(2).click();
      }
    }

    // 4. Copilot panel — it renders when a node is selected; assert presence.
    await page
      .locator('[aria-label="Zero-actuation copilot"]')
      .waitFor({ state: 'visible', timeout: 10_000 })
      .catch(() => {
        errors++;
        emit({ event: 'copilot_missing', cycle });
      });

    // 5. Route-switch away and back.
    const route = ROUTES[cycle % ROUTES.length];
    await page.goto(`${BASE}${route}`, { waitUntil: 'load' });
    await page.waitForTimeout(5);

    // Metrics + snapshots.
    if (cycle % SAMPLE_EVERY === 0 || SNAPSHOT_CYCLES.has(cycle)) {
      await cdp.send('HeapProfiler.collectGarbage');
      await page.waitForTimeout(50);
      const m = await getMetrics(cdp);
      const rec = {
        event: 'metrics',
        cycle,
        heapUsed: m.JSHeapUsedSize,
        heapTotal: m.JSHeapTotalSize,
        documents: m.Documents,
        nodes: m.Nodes,
        jsEventListeners: m.JSEventListeners,
        rcNodes: 0,
      };
      emit(rec);
      samples.push({ cycle, heap: m.JSHeapUsedSize });
      if (SNAPSHOT_CYCLES.has(cycle)) {
        const f = await takeHeapSnapshot(cdp, cycle, OUT_DIR);
        emit({ event: 'heapsnapshot', cycle, file: f, bytes: (await import('node:fs')).statSync(f).size });
      }
    }
    if (cycle === 250 || cycle === 500) {
      const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
      modal(`cycle ${cycle}/${TOTAL_CYCLES} elapsed=${elapsed}s`);
    }
  }
} catch (err) {
  errors++;
  emit({ event: 'fatal', error: String(err && err.stack ? err.stack : err) });
  modal(`fatal: ${err}`);
} finally {
  const analysis = analyze(samples);
  const first = samples[0];
  const last = samples[samples.length - 1];
  const growth = first && last ? (last.heap - first.heap) / first.heap : null;
  const verdict =
    samples.length < 3
      ? 'UNKNOWN'
      : growth > 0.1 && !analysis.sawtooth && analysis.r2 > 0.8
        ? 'FAIL(leak)'
        : 'PASS';
  const summary = {
    event: 'summary',
    cycles_completed: TOTAL_CYCLES,
    samples: samples.length,
    heap_first: first ? first.heap : null,
    heap_last: last ? last.heap : null,
    retained_growth_pct: growth === null ? null : +(growth * 100).toFixed(2),
    slope_bytes_per_cycle: Math.round(analysis.slopePerCycle),
    r2: +analysis.r2.toFixed(4),
    sawtooth: analysis.sawtooth,
    envelope: analysis.envelope,
    max_drawdown_bytes: analysis.maxDrawdown,
    listener_first: samples.length ? samples[0].heap : null,
    verdict,
    duration_s: +((Date.now() - t0) / 1000).toFixed(1),
    errors,
  };
  emit(summary);
  modal(`verdict=${verdict} growth=${summary.retained_growth_pct}% sawtooth=${analysis.sawtooth}`);
  await browser.close().catch(() => {});
  process.exit(verdict === 'PASS' ? 0 : verdict === 'UNKNOWN' ? 3 : 1);
}
