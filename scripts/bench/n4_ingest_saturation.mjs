#!/usr/bin/env node
// N-4 ingest saturation driver. 3x60s windows against next start.
// Mix per window: valid-signature gzip JSON bodies (rate-limit leg) and
// invalid-signature bodies (401 rejection leg). Hand-rolled fetch pool.
//
// Env: TARGET (default http://127.0.0.1:3100), WINDOWS=3, SECS=60,
//      RPS=5000, HMAC_KEY (default n4-dev-key), OUT (jsonl path).
// JSONL row per window: {window, rpsTarget, achievedRps, p50,p95,p99,
//   statusCounts, socketErrors, heapSamples:[{t,rss,heapUsed}]}

import { createHmac, randomBytes } from "node:crypto";
import { gzipSync } from "node:zlib";
import { writeFileSync, appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const TARGET = process.env.TARGET ?? "http://127.0.0.1:3100";
const WINDOWS = Number(process.env.WINDOWS ?? 3);
const SECS = Number(process.env.SECS ?? 60);
const RPS = Number(process.env.RPS ?? 5000);
const HMAC_KEY = process.env.HMAC_KEY ?? "n4-dev-key";
const OUT = process.env.OUT ?? "docs/jira/v26.10.14/bench/n4-ingest.jsonl";

const INGEST = `${TARGET}/api/v1/ingest`;
const METRICS = `${TARGET}/api/v1/ingest`;

function payload() {
  const body = Buffer.from(
    JSON.stringify({
      ts: Date.now(),
      nonce: randomBytes(8).toString("hex"),
      events: Array.from({ length: 20 }, (_, i) => ({ i, v: randomBytes(16).toString("hex") })),
    }),
  );
  return gzipSync(body);
}

function sign(buf, bad) {
  const h = createHmac("sha256", HMAC_KEY).update(buf).digest("hex");
  if (!bad) return h;
  // deterministic corruption: flip first hex char
  return (h[0] === "0" ? "1" : "0") + h.slice(1);
}

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

async function fetchOnce(buf, sig) {
  const t0 = performance.now();
  try {
    const res = await fetch(INGEST, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "content-encoding": "gzip",
        "x-smalt-signature": sig,
      },
      body: buf,
    });
    await res.arrayBuffer(); // drain
    const dt = performance.now() - t0;
    return { ok: true, status: res.status, dt };
  } catch (err) {
    return { ok: false, status: 0, dt: performance.now() - t0, err: String(err?.cause?.code ?? err?.message ?? err) };
  }
}

async function heapSample() {
  try {
    const res = await fetch(METRICS, { signal: AbortSignal.timeout(5000) });
    const j = await res.json();
    return { t: Date.now(), rss: j.heap.rss, heapUsed: j.heap.heapUsed };
  } catch {
    return null;
  }
}

async function runWindow(n) {
  const lat = [];
  const statusCounts = {};
  const socketErrors = {};
  const heapSamples = [];
  const durationMs = SECS * 1000;
  const intervalMs = 1000 / RPS;
  const start = performance.now();
  const stopAt = start + durationMs;

  let sent = 0;
  const concurrency = 400;
  const workers = [];

  // Closed-loop pool: `concurrency` workers firing as fast as possible,
  // paced globally to the RPS target.
  let scheduleErr = 0;
  const paced = async (workerId) => {
    for (;;) {
      const now = performance.now();
      if (now >= stopAt) return;
      const slot = sent++;
      const due = start + slot * intervalMs;
      const waitMs = due - performance.now();
      if (waitMs > 0) await new Promise((r) => setTimeout(r, waitMs));
      if (performance.now() >= stopAt) return;
      const bad = slot % 5 === 4; // 20% invalid-signature leg
      const buf = payload();
      const r = await fetchOnce(buf, sign(buf, bad));
      if (r.ok) {
        statusCounts[r.status] = (statusCounts[r.status] ?? 0) + 1;
        lat.push(r.dt);
      } else {
        const code = r.err ?? "unknown";
        socketErrors[code] = (socketErrors[code] ?? 0) + 1;
        scheduleErr++;
      }
    }
  };

  const sampler = (async () => {
    while (performance.now() < stopAt) {
      const h = await heapSample();
      if (h) heapSamples.push(h);
      await new Promise((r) => setTimeout(r, 2000));
    }
    const h = await heapSample();
    if (h) heapSamples.push(h);
  })();

  for (let i = 0; i < concurrency; i++) workers.push(paced(i));
  await Promise.all(workers);
  await sampler;

  const wallSecs = (performance.now() - start) / 1000;
  lat.sort((a, b) => a - b);
  const total = lat.length + scheduleErr;
  const row = {
    window: n,
    ts: new Date().toISOString(),
    rpsTarget: RPS,
    sent: total,
    achievedRps: Number((total / wallSecs).toFixed(1)),
    latencyMs: { p50: percentile(lat, 50), p95: percentile(lat, 95), p99: percentile(lat, 99), n: lat.length },
    statusCounts,
    socketErrors,
    heapSamples,
  };
  return row;
}

// ---- main ----
mkdirSync(dirname(OUT), { recursive: true });

// warmup: verify server up + signature court sanity (1 valid, 1 bad)
{
  const buf = payload();
  const good = await fetchOnce(buf, sign(buf, false));
  const badBuf = payload();
  const bad = await fetchOnce(badBuf, sign(badBuf, true));
  console.error(`[warmup] valid-sig status=${good.status} socketErr=${good.err ?? "-"} ; bad-sig status=${bad.status}`);
  if (good.status !== 202 || bad.status !== 401) {
    console.error("[warmup] FATAL: signature court failed preconditions");
    process.exit(2);
  }
}

const rows = [];
for (let w = 1; w <= WINDOWS; w++) {
  process.stderr.write(`[window ${w}/${WINDOWS}] running ${SECS}s @ ${RPS} rps target...\n`);
  const row = await runWindow(w);
  rows.push(row);
  appendFileSync(OUT, JSON.stringify(row) + "\n");
  const totalRejected = row.statusCounts["429"] ?? 0;
  const bad401 = row.statusCounts["401"] ?? 0;
  process.stderr.write(
    `[window ${w}] achieved=${row.achievedRps} rps, p50=${row.latencyMs.p50}ms p95=${row.latencyMs.p95}ms p99=${row.latencyMs.p99}ms, 202=${row.statusCounts["202"] ?? 0} 429=${totalRejected} 401=${bad401}, socketErr=${JSON.stringify(row.socketErrors)}\n`,
  );
}

console.error(`[done] wrote ${rows.length} rows to ${OUT}`);
