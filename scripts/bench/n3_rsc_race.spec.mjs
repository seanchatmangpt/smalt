#!/usr/bin/env node
// N-3 RSC streaming race bench — rapid client navigation during server streaming.
// Usage: node scripts/bench/n3_rsc_race.spec.mjs [--base http://127.0.0.1:3100] [--rounds 50]
import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const BASE = arg("base", "http://127.0.0.1:3100");
const ROUNDS = parseInt(arg("rounds", "50"), 10);
const OUT = path.resolve("docs/jira/v26.10.14/bench/n3-rsc-race.jsonl");
fs.mkdirSync(path.dirname(OUT), { recursive: true });

const browser = await chromium.launch();
const ctx = await browser.newContext();
const page = await ctx.newPage();
const cdp = await ctx.newCDPSession(page);

await cdp.send("Network.enable");
await cdp.send("Performance.enable");
await cdp.send("Page.enable");

// --- CDP network emulation: 100ms jitter + chunk reordering simulation -----
// emulateNetworkConditions gives the base latency; per-request jitter (0-100ms)
// and chunk reordering pressure come from route-level randomized delay.
await cdp.send("Network.emulateNetworkConditions", {
  offline: false,
  latency: 50,
  downloadThroughput: 2 * 1024 * 1024,
  uploadThroughput: 2 * 1024 * 1024,
});

const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e?.message ?? e)));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const jitter = () => Math.random() * 100;

// Route-level jitter + chunk reorder pressure on RSC/document fetches.
// Reordering: randomized per-request delay decouples arrival order from
// server emission order across the 3 Suspense chunks' fetches.
await page.route("**/bench/audit/**", async (route) => {
  await sleep(jitter());
  await route.continue();
});

// --- fetch connection bookkeeping ------------------------------------------
const auditReqs = new Map(); // requestId -> {url, phase}
cdp.on("Network.requestWillBeSent", (p) => {
  if (/\/bench\/audit/.test(p.request.url))
    auditReqs.set(p.requestId, { url: p.request.url, phase: "pending" });
});
cdp.on("Network.responseReceived", (p) => {
  const r = auditReqs.get(p.requestId);
  if (r) r.phase = "response";
});
cdp.on("Network.loadingFinished", (p) => {
  const r = auditReqs.get(cdpRequestId(p));
  if (r) r.phase = "finished";
});
cdp.on("Network.loadingFailed", (p) => {
  const r = auditReqs.get(cdpRequestId(p));
  if (r) r.phase = "aborted";
});
function cdpRequestId(p) {
  return p.requestId;
}

// --- heap sampling -----------------------------------------------------------
async function heap() {
  const { metrics } = await cdp.send("Performance.getMetrics");
  return metrics.find((m) => m.name === "JSHeapUsedSize").value; // bytes
}

// --- hydration flash probe ---------------------------------------------------
await page.addInitScript(() => {
  window.__n3 = { fallbacksAfterHydration: 0, hydratedAt: 0 };
  new MutationObserver((muts) => {
    if (!window.__n3.hydratedAt) return;
    for (const m of muts)
      for (const n of m.addedNodes)
        if (n.nodeType === 1 && n.matches?.("[data-fallback]"))
          window.__n3.fallbacksAfterHydration++;
  }).observe(document.documentElement, { childList: true, subtree: true });
});

// --- run ---------------------------------------------------------------------
const rows = [];
const t0 = Date.now();
await page.goto(`${BASE}/bench/audit/1`, { waitUntil: "commit" });
await page.waitForSelector('[data-chunk="c"]', { timeout: 15000 });
const heapStart = await heap();
let hydrationFlashCount = 0;

for (let round = 1; round <= ROUNDS; round++) {
  const target = (round % 5) + 1; // 1..5, always a different sibling mostly
  const errBefore = pageErrors.length;
  const pendingBefore = [...auditReqs.values()].filter(
    (r) => r.phase === "pending",
  ).length;
  const roundStart = Date.now();

  // Click DURING the prior stream: navigate immediately, then click the next
  // sibling before chunk "c" (600ms) would land.
  await page.click(`nav[data-siblings] a[href="/bench/audit/${target}"]`);
  await sleep(120); // next click fires before the 600ms chunk resolves

  const heapNow = await heap();
  const pendingAfter = [...auditReqs.values()].filter(
    (r) => r.phase === "pending",
  ).length;
  const abortedByNav = [...auditReqs.values()].filter(
    (r) => r.phase === "aborted",
  ).length;
  const row = {
    ts: new Date().toISOString(),
    lane: "N-3",
    bench: "n3-rsc-race",
    round,
    target: `/bench/audit/${target}`,
    pageErrors: pageErrors.length - errBefore,
    pendingAfter,
    abortedByNav,
    heapBytes: heapNow,
    heapDeltaFromStart: heapNow - heapStart,
    hydrationFlashCount,
    durationMs: Date.now() - roundStart,
  };
  rows.push(row);
  fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
}

const heapEnd = await heap();
const heapGrowth = heapEnd - heapStart;
let pendingAtEnd = [...auditReqs.values()].filter(
  (r) => r.phase === "pending",
).length;
await sleep(1000);
pendingAtEnd = [...auditReqs.values()].filter(
  (r) => r.phase === "pending",
).length;

// Network.getResponseBody on aborted fetches is expected to fail — sanity check.
let getResponseBodyFailures = 0;
for (const [id, r] of auditReqs) {
  if (r.phase === "aborted") {
    try {
      await cdp.send("Network.getResponseBody", { requestId: id });
    } catch {
      getResponseBodyFailures++;
    }
  }
}

// hydration flash count (informational)
try {
  await page.waitForSelector("[data-page]", { timeout: 5000 });
  hydrationFlashCount = await page.evaluate(
    () => window.__n3.fallbacksAfterHydration,
  );
} catch {}

const summary = {
  ts: new Date().toISOString(),
  lane: "N-3",
  bench: "n3-rsc-race",
  type: "summary",
  rounds: ROUNDS,
  base: BASE,
  pageErrorsTotal: pageErrors.length,
  heapStartBytes: heapStart,
  heapEndBytes: heapEnd,
  heapGrowthBytes: heapGrowth,
  heapGrowthMB: +(heapGrowth / 1048576).toFixed(2),
  pendingAtEnd,
  abortedByNavTotal: [...auditReqs.values()].filter((r) => r.phase === "aborted").length,
  getResponseBodyFailures,
  hydrationFlashCount,
  wallMs: Date.now() - t0,
  falsifiers: {
    unhandledRejections:
      pageErrors.length === 0
        ? "PASS"
        : `FAIL (${pageErrors.length} pageerror events)`,
    heapGrowthUnder150MB:
      heapGrowth < 150 * 1048576
        ? "PASS"
        : `FAIL (${(heapGrowth / 1048576).toFixed(1)} MB > 150 MB)`,
    noLingeringPending:
      pendingAtEnd === 0
        ? "PASS"
        : `FAIL (${pendingAtEnd} lingering pending at end)`,
  },
};
fs.appendFileSync(OUT, JSON.stringify(summary) + "\n");
console.log(JSON.stringify(summary, null, 2));
console.log(`rows: ${rows.length} -> ${OUT}`);

await browser.close();
const failed = Object.values(summary.falsifiers).some((v) =>
  String(v).startsWith("FAIL"),
);
process.exit(failed ? 1 : 0);
