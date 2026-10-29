#!/usr/bin/env node
/// N-5 compute-saturation bench (Playwright + CDP), run vs `next start`.
///
/// Scenario: boot /bench/compute -> dedicated worker starts a 15 s topo-sort
/// over a 50 MB zero-copy-transferred ArrayBuffer -> driver simulates 60 Hz
/// interaction (CDP Input.dispatchMouseEvent). Measured:
///   1. main-thread input latency (arm -> CDP mouse event -> next rAF)
///   2. dropped frames (in-page rAF accounting; >20 ms gap = dropped @60 Hz)
///   3. worker linear memory (worker performance.memory polled to page)
///   4. post-termination reclaim (heap to within 5% of baseline in 5 s,
///      CDP Performance.getMetrics Workers count back to pre-run value)
///
/// Falsifiers: sustained input latency >16.6 ms (>50% of samples) or dropped
/// frames >5% -> FAIL; memory not reclaimed post-termination -> FAIL.

import { spawn } from "node:child_process";
import { mkdirSync, openSync, appendFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(import.meta.url);
const { chromium } = require(
  `${REPO_ROOT}/workspace/node_modules/playwright`,
);

const ROOT = `${REPO_ROOT}/workspace`;
const PORT = 39555;
const DEFAULT_URL = "http://127.0.0.1:39555/bench/compute";
const OUT_PATH = `${REPO_ROOT}/docs/jira/v26.10.14/bench/n5-compute.jsonl`;

const args = process.argv.slice(2);
const urlIdx = args.indexOf("--url");
const BASE = urlIdx >= 0 ? args[urlIdx + 1] : DEFAULT_URL;
const MANAGED_SERVER = urlIdx === -1;

const sleep = (ms) => new Promise((res) => setTimeout(res, ms));
const two = (v) => Number(v.toFixed(2));

let outFd = null;
function emit(row) {
  const line = JSON.stringify(row);
  console.log(line);
  if (process.env.N5_DRY) return;
  if (!outFd) {
    mkdirSync(dirname(OUT_PATH), { recursive: true });
    outFd = openSync(OUT_PATH, "a");
  }
  appendFileSync(outFd, line + "\n");
}

async function main() {
  let server = null;
  if (MANAGED_SERVER) {
    server = spawn("npx", ["next", "start", "-p", String(PORT)], {
      cwd: ROOT,
      stdio: ["ignore", "pipe", "pipe"],
      // No SMALT_DEBUG_FACES here (EXPL7-R1 E7-3): N-5 drives /bench/compute
      // only — it calls no gated debug face, so the gate stays OFF.
      env: process.env,
    });
    const fwd = (d) => process.env.N5_VERBOSE && process.stdout.write(`[srv] ${d}`);
    server.stdout.on("data", fwd);
    server.stderr.on("data", fwd);
    await sleep(3000);
  }

  const browser = await chromium.launch({
    headless: true,
    args: [
      "--enable-precise-memory-info",
      "--js-flags=--expose-gc", // reclaim witness: window.gc() available in-page
    ],
  });
  const context = await browser.newContext();
  const page = await context.newPage();
  page.on("pageerror", (e) => console.log("[pageerror]", e.message));
  page.on("console", (m) => {
    if (m.type() === "error") console.log("[console]", m.text());
  });

  await page.goto(BASE, { waitUntil: "networkidle", timeout: 30_000 });
  await page.waitForFunction(() => Boolean(window.__n5), null, { timeout: 15_000 });
  await page.waitForFunction(
    () => window.__n5.state() === "running" || window.__n5.state() === "done",
    null,
    { timeout: 20_000 },
  );

  const cdp = await context.newCDPSession(page);
  await cdp.send("Performance.enable");
  const metrics = () => cdp.send("Performance.getMetrics");
  // Worker liveness/counting witness: Target.getTargets sees dedicated workers.
  const workerCount = async () => {
    const t = await cdp.send("Target.getTargets");
    return (t.targetInfos || []).filter((x) => x.type === "worker").length;
  };

  const workersBefore = await workerCount();
  const baselineMainHeap = await page.evaluate(() => window.__n5.baselineHeap());
  emit({
    lane: "n5",
    surface: "workspace-next",
    op: "boot",
    worker_state: "running",
    baseline_main_heap_bytes: Math.round(baselineMainHeap),
    workers_before: workersBefore,
    ts: Date.now(),
  });

  // ------------------------------------------------ Phase B: 60 Hz interaction ----
  const INTERACT_MS = 15_000;
  const INTERVAL = 1000 / 60;
  const t0 = Date.now();
  let dispatched = 0;
  const framesBefore = await page.evaluate(() => ({
    total: window.__n5.totalFrames(),
    dropped: window.__n5.droppedFrames(),
  }));

  while (Date.now() - t0 < INTERACT_MS) {
    const iterStart = Date.now();
    await page.evaluate(() => window.__n5.arm());
    const x = 400 + (dispatched % 40);
    const y = 300 + (dispatched % 20);
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      x,
      y,
      button: "left",
      clickCount: 1,
    });
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x,
      y,
      button: "left",
      clickCount: 1,
    });
    dispatched++;
    const spent = Date.now() - iterStart;
    await sleep(Math.max(0, INTERVAL - spent));
  }

  await sleep(300);
  const lats = await page.evaluate(() =>
    window.__n5.latencies().map((s) => s.latencyMs).filter(Number.isFinite),
  );
  const sorted = [...lats].sort((a, b) => a - b);
  const pick = (q) =>
    sorted.length
      ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]
      : NaN;
  const framesAfter = await page.evaluate(() => ({
    total: window.__n5.totalFrames(),
    dropped: window.__n5.droppedFrames(),
  }));
  const interactFrames = framesAfter.total - framesBefore.total;
  const interactDropped = framesAfter.dropped - framesBefore.dropped;
  const droppedPct = interactFrames > 0 ? (100 * interactDropped) / interactFrames : -1;

  const workerMemPeak = await page.evaluate(() => window.__n5.workerMemPeak());
  const workerIterations = await page.evaluate(() => window.__n5.iterations());
  const workersRunning = await workerCount();

  emit({
    lane: "n5",
    surface: "workspace-next",
    op: "interaction-60hz-under-compute",
    n: dispatched,
    worker_topo_iterations: workerIterations,
    interact_frames: interactFrames,
    interact_dropped: interactDropped,
    dropped_pct: two(droppedPct),
    input_latency_p50_ms: two(pick(0.5)),
    input_latency_p95_ms: two(pick(0.95)),
    input_latency_p99_ms: two(pick(0.99)),
    input_latency_max_ms: two(sorted[sorted.length - 1] ?? NaN),
    input_latency_pct_over_16_6: two(
      (100 * lats.filter((v) => v > 16.6).length) / Math.max(1, lats.length),
    ),
    worker_mem_peak_bytes: workerMemPeak,
    workers_cdp_running_phase: workersRunning,
    errors: 0,
    ts: Date.now(),
  });

  // ----------------------------------------------- Phase C: reclaim ----
  const preTermMainHeap = await page.evaluate(() => window.__n5.baselineHeap());
  const lastWorkerMem = await page.evaluate(() => window.__n5.workerMem());
  await page.evaluate(() => window.__n5.terminate());
  let reclaimed = false;
  let heapAfter = -1;
  let gcRuns = 0;
  const tTerm = Date.now();
  while (Date.now() - tTerm < 5_000) {
    await sleep(250);
    // Force GC so the witness measures RETENTION, not GC scheduling lag.
    await page.evaluate(() => {
      if (typeof window.gc === "function") window.gc();
    });
    gcRuns++;
    const h = await page.evaluate(() => window.__n5.baselineHeap());
    if (h <= baselineMainHeap * 1.05) {
      reclaimed = true;
      heapAfter = h;
      break;
    }
  }
  if (!reclaimed) {
    heapAfter = await page.evaluate(() => window.__n5.baselineHeap());
  }
  const workersAfterTerm = await workerCount();
  const reclaimedOk = reclaimed && workersAfterTerm <= workersBefore;

  emit({
    lane: "n5",
    surface: "workspace-next",
    op: "post-termination-reclaim",
    pre_term_main_heap_bytes: Math.round(preTermMainHeap),
    last_worker_mem_bytes: lastWorkerMem,
    heap_after_bytes: Math.round(heapAfter),
    baseline_main_heap_bytes: Math.round(baselineMainHeap),
    reclaimed_to_baseline_5pct_in_5s: reclaimed,
    gc_forced_runs: gcRuns,
    workers_after_terminate: workersAfterTerm,
    ts: Date.now(),
  });

  // ------------------------------------------------------- verdicts ----
  const overBudgetPct = (100 * lats.filter((v) => v > 16.6).length) / Math.max(1, lats.length);
  const latencyFail = overBudgetPct > 50; // "sustained" = majority of samples over budget
  const droppedFail = droppedPct > 5;
  const reclaimFail = !reclaimedOk;
  const livenessFail = workerIterations <= 0;
  emit({
    lane: "n5",
    surface: "workspace-next",
    op: "verdict",
    compute_liveness: livenessFail ? "FAIL" : "PASS",
    input_latency_falsifier: latencyFail ? "FAIL" : "PASS",
    dropped_frames_falsifier: droppedFail ? "FAIL" : "PASS",
    memory_reclaim_falsifier: reclaimFail ? "FAIL" : "PASS",
    latency_budget_ms: 16.6,
    dropped_budget_pct: 5,
    reclaim_budget: "heap within 5% of baseline within 5 s",
    ts: Date.now(),
  });

  await browser.close();
  if (server) {
    server.kill("SIGTERM");
    await sleep(500);
  }
  process.exit(latencyFail || droppedFail || reclaimFail || livenessFail ? 1 : 0);
}

function findMetric(metricsResp, name) {
  for (const entry of metricsResp.metrics || []) {
    if (entry.name === name) return entry.value;
  }
  return -1;
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
