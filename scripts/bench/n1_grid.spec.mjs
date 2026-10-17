#!/usr/bin/env node
/**
 * N-1 grid lifecycle stress — Playwright + CDP driver.
 *
 * Scenario: SSR init (TTFB), hydration, then a 30s mutation burst
 * (programmatic scroll ~100 rows/s + 50 patch events/s via window.__bench).
 * Measured via CDP: dropped frames (Tracing DrawFrame vs 60Hz), detached-DOM
 * leak (DOMCounter Nodes delta after forced GC), heap delta, long tasks.
 *
 * FALSIFIER: frame-drop rate > 5% OR detached nodes > 500 -> FAIL.
 *
 * Usage: node scripts/bench/n1_grid.spec.mjs [--base-url http://127.0.0.1:3311]
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// playwright resolves from the workspace checkout (script lives outside it).
const workspaceRequire = createRequire(path.resolve(__dirname, '..', '..', 'workspace', 'package.json'));
const { chromium } = workspaceRequire('playwright');
const REPO = path.resolve(__dirname, '..', '..');
const JSONL = path.join(REPO, 'docs', 'jira', 'v26.10.14', 'bench', 'n1-grid.jsonl');
const TRACE = '/tmp/n1-grid-trace.json';

const arg = process.argv.indexOf('--base-url');
const BASE = arg > -1 ? process.argv[arg + 1] : 'http://127.0.0.1:3311';
const URL = `${BASE}/bench/grid`;

const BURST_SECONDS = 30;
const SCROLL_ROWS_PER_SEC = 100;
const PATCHES_PER_SEC = 50;
const FPS = 60;

const DROP_RATE_THRESHOLD = 0.05;
const DETACHED_THRESHOLD = 500;

function metricsFrom(cdpMetrics) {
  const map = {};
  for (const m of cdpMetrics) map[m.name] = m.value;
  return map;
}

async function gcAndMetrics(cdp) {
  await cdp.send('HeapProfiler.collectGarbage');
  await new Promise((r) => setTimeout(r, 500));
  const { metrics } = await cdp.send('Performance.getMetrics');
  return metricsFrom(metrics);
}

const rows = [];

function record(metric, value, threshold, status, unit = '') {
  rows.push({ scenario: 'n1', metric, value, threshold, status, unit });
  console.log(`  ${metric}=${value}${unit} threshold=${threshold}${unit} -> ${status}`);
}

// ---------------------------------------------------------------------------

const browser = await chromium.launch({
  headless: true,
  args: ['--enable-precise-memory-info', '--run-all-compositor-stages-before-draw'],
});
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);

  await cdp.send('Performance.enable');
  await cdp.send('HeapProfiler.enable');
  await cdp.send('Network.enable');

  // TTFB from CDP Network monotonic timestamps (document request only).
  const netTimes = new Map(); // requestId -> requestWillBeSent ts
  let docTtfbSec = null;
  cdp.on('Network.requestWillBeSent', (p) => {
    if (p.request.url === URL) netTimes.set(p.requestId, p.timestamp);
  });
  cdp.on('Network.responseReceived', (p) => {
    const t0 = netTimes.get(p.requestId);
    if (t0 !== undefined && p.response.url === URL && p.type === 'Document') {
      docTtfbSec = p.timestamp - t0;
    }
  });

  // --- SSR init: TTFB of the document response (CDP Network) ----------------
  let ttfbMs = null; // set from CDP Network after goto

  console.log(`navigating ${URL}`);
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60_000 });
  ttfbMs = docTtfbSec === null ? null : Math.round(docTtfbSec * 1e6) / 1e3;

  // --- hydration ------------------------------------------------------------
  await page.waitForFunction(() => {
    const w = window;
    return Boolean(w.__bench && w.__bench.hydrated);
  }, null, { timeout: 60_000 });
  const hydrationMs = await page.evaluate(() => {
    const mark = performance.getEntriesByName('smalt-bench:hydrated')[0];
    return mark ? mark.startTime : -1;
  });

  // --- baseline --------------------------------------------------------------
  const before = await gcAndMetrics(cdp);

  // In-page observers: long tasks, DOM churn (added/removed), rAF ticks.
  await page.evaluate(() => {
    const w = window;
    w.__lt = { count: 0, totalMs: 0 };
    try {
      new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          w.__lt.count += 1;
          w.__lt.totalMs += e.duration;
        }
      }).observe({ type: 'longtask', buffered: false });
    } catch { /* longtask unsupported */ }
    w.__churn = { added: 0, removed: 0 };
    const grid = document.querySelector('[role="grid"]');
    if (grid) {
      new MutationObserver((muts) => {
        for (const m of muts) {
          w.__churn.removed += m.removedNodes.length;
          w.__churn.added += m.addedNodes.length;
        }
      }).observe(grid, { childList: true, subtree: true });
    }
    w.__raf = { ticks: 0, active: true };
    const tick = () => {
      if (!w.__raf.active) return;
      w.__raf.ticks += 1;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });

  // --- CDP tracing (frames) ---------------------------------------------------
  await cdp.send('Tracing.start', {
    traceConfig: {
      includedCategories: ['devtools.timeline', 'disabled-by-default-devtools.timeline.frame'],
    },
  });

  // --- 30s mutation burst ------------------------------------------------------
  console.log(`burst: ${BURST_SECONDS}s, scroll ${SCROLL_ROWS_PER_SEC} rows/s, ${PATCHES_PER_SEC} patches/s`);
  await page.evaluate(({ seconds, rps }) => {
    window.__bench.scrollBurst(seconds, rps);
  }, { seconds: BURST_SECONDS, rps: SCROLL_ROWS_PER_SEC });
  const patchTimer = setInterval(() => {
    page.evaluate(() => window.__bench.applyPatches(1)).catch(() => {});
  }, 1000 / PATCHES_PER_SEC);

  await new Promise((r) => setTimeout(r, (BURST_SECONDS + 1) * 1000));
  clearInterval(patchTimer);

  const churn = await page.evaluate(() => ({
    churn: window.__churn,
    rafTicks: window.__raf.ticks,
    longTasks: { ...window.__lt },
    patchesApplied: window.__bench.patches,
  }));
  await page.evaluate(() => {
    window.__raf.active = false;
  });

  const traceComplete = new Promise((resolve) => {
    const collect = [];
    cdp.on('Tracing.dataCollected', (p) => collect.push(...p.value));
    cdp.on('Tracing.tracingComplete', () => resolve(collect));
  });
  cdp.send('Tracing.end').catch(() => {});
  const traceEvents = await traceComplete;
  fs.writeFileSync(TRACE, JSON.stringify({ traceEvents }));

  // --- post burst --------------------------------------------------------------
  await new Promise((r) => setTimeout(r, 1000));
  const after = await gcAndMetrics(cdp);

  // --- derived metrics -----------------------------------------------------------
  const drawFrames = traceEvents.filter((e) => e.name === 'DrawFrame').length;
  const expected = BURST_SECONDS * FPS;
  const dropRate = Math.max(0, 1 - drawFrames / expected);
  const rafRate = Math.max(0, 1 - churn.rafTicks / expected);
  const nodesDelta = (after.Nodes ?? 0) - (before.Nodes ?? 0);
  const listenersDelta = (after.JSEventListeners ?? 0) - (before.JSEventListeners ?? 0);
  const heapDeltaBytes = Math.round((after.JSHeapUsedSize ?? 0) - (before.JSHeapUsedSize ?? 0));

  console.log('\nresults:');
  record('ttfb_ms', ttfbMs === null ? -1 : Math.round(ttfbMs * 100) / 100, 'info', 'INFO', 'ms');
  record('hydration_ms', Math.round(hydrationMs * 100) / 100, 'info', 'INFO', 'ms');
  record('draw_frames', drawFrames, expected, drawFrames >= expected * 0.95 ? 'PASS' : 'FAIL', '');
  record('frame_drop_rate', Math.round(dropRate * 10000) / 10000, DROP_RATE_THRESHOLD, dropRate <= DROP_RATE_THRESHOLD ? 'PASS' : 'FAIL', 'ratio');
  record('raf_drop_rate', Math.round(rafRate * 10000) / 10000, DROP_RATE_THRESHOLD, rafRate <= DROP_RATE_THRESHOLD ? 'PASS' : 'FAIL', 'ratio');
  record('detached_nodes_leak', nodesDelta, DETACHED_THRESHOLD, nodesDelta <= DETACHED_THRESHOLD ? 'PASS' : 'FAIL', 'nodes');
  record('dom_churn_removed', churn.churn.removed, 'info', 'INFO', 'nodes');
  record('dom_churn_added', churn.churn.added, 'info', 'INFO', 'nodes');
  record('js_event_listener_delta', listenersDelta, 50, Math.abs(listenersDelta) <= 50 ? 'PASS' : 'FAIL', 'count');
  record('heap_delta_mb', Math.round((heapDeltaBytes / (1024 * 1024)) * 100) / 100, 50, heapDeltaBytes / (1024 * 1024) <= 50 ? 'PASS' : 'FAIL', 'MB');
  record('long_task_count', churn.longTasks.count, 'info', churn.longTasks.count > 0 ? 'INFO' : 'INFO', 'count');
  record('long_task_total_ms', Math.round(churn.longTasks.totalMs), 'info', 'INFO', 'ms');
  record('patches_applied', churn.patchesApplied, PATCHES_PER_SEC * BURST_SECONDS * 0.9, churn.patchesApplied >= PATCHES_PER_SEC * BURST_SECONDS * 0.9 ? 'PASS' : 'FAIL', 'count');

  const verdict = rows.some((r) => r.status === 'FAIL') ? 'FAIL' : 'PASS';
  console.log(`\nFALSIFIER VERDICT: ${verdict}`);

  // --- JSONL ----------------------------------------------------------------------
  fs.mkdirSync(path.dirname(JSONL), { recursive: true });
  fs.appendFileSync(JSONL, rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
  console.log(`appended ${rows.length} rows -> ${JSONL}`);
  process.exitCode = verdict === 'FAIL' ? 1 : 0;
} finally {
  await browser.close();
}
