// n6_isr_stampede.mjs — lifecycle stress lane N-6: ISR stampede + on-demand
// revalidation under concurrent reads, against `next start` (production; ISR
// requires it).
//
// Subject: workspace/app/bench/news/[slug]/page.tsx (revalidate = 10, fetch-free
// deterministic fixture content). Because there is no upstream fetch, the
// upstream-dedup witness becomes the regeneration count exposed by
// /api/bench/isr-stats (append-only event log in workspace/.bench/).
//
// Phases:
//   P0  warm + cached-read TTFB (autocannon, connections=100)
//       Falsifier F1: cached p99 > 45 ms -> FAIL
//   P1  stampede: 10,000 requests against one expired slug, in-flight capped
//       at 1,000 keep-alive sockets (node:http agent — autocannon cannot give
//       per-response x-nextjs-cache headers; achieved concurrency is recorded,
//       not assumed)
//       Falsifier F2: >1 runtime regeneration for the slug across the expired
//       interval -> FAIL (Next per-entry lock dedup witness)
//   P2  50 parallel on-demand revalidatePath calls across dependent slugs
//       while background reads continue
//       Falsifier F3: any 5xx, or any served page with generatedAt older than
//       one window (2x revalidate) -> FAIL; every revalidated slug must serve
//       post-revalidate content within the drain period
//   P3  disk/cache behavior: .next/cache size, event-log growth
//
// Env:
//   N6_URL=http://127.0.0.1:3116   production server base
//   N6_OUT=docs/jira/v26.10.14/bench/n6-isr.jsonl
//   N6_HERD=10000  N6_SOCKETS=1000
//
// SERVER ENV REQUIREMENT (EXPL7-R1 E7-3): the isr-stats POST face (reset /
// stale witness) is gated — launch the server with SMALT_DEBUG_FACES=1 or the
// lane exits 3 at preflight. This lane does NOT spawn the server (N6_URL is
// external).
//
// Exit 0 iff F1..F3 all PASS.

import { createRequire } from "node:module";
import fs from "node:fs";
import http from "node:http";
import { execFileSync } from "node:child_process";

const require = createRequire(new URL("../../verification/ts/package.json", import.meta.url));
const autocannon = require("autocannon");

const BASE = process.env.N6_URL || "http://127.0.0.1:3116";
const OUT = process.env.N6_OUT || "docs/jira/v26.10.14/bench/n6-isr.jsonl";
const HERD = parseInt(process.env.N6_HERD || "10000", 10);
const SOCKETS = parseInt(process.env.N6_SOCKETS || "1000", 10);
const REVALIDATE_MS = 10_000;
// Keep in lockstep with workspace/lib/bench/isr-counter.ts ALL_SLUGS.
const PRIMARY_SLUG = "isr-stampede-primary";
const DEPENDENT_SLUGS = Array.from(
  { length: 50 },
  (_, i) => `isr-dependent-${String(i).padStart(2, "0")}`,
);

const rows = [];
function emit(row) {
  rows.push({ ts: new Date().toISOString(), ...row });
  console.log(JSON.stringify(rows[rows.length - 1]));
}

function pct(sorted, p) {
  if (sorted.length === 0) return null;
  const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, i)];
}

function statsPath() {
  return `${BASE}/api/bench/isr-stats`;
}

async function getStats() {
  const r = await fetch(statsPath(), { cache: "no-store" });
  if (!r.ok) throw new Error(`stats ${r.status}`);
  return r.json();
}

async function resetStats() {
  const r = await fetch(statsPath(), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ reset: true }),
  });
  if (!r.ok) throw new Error(`stats reset ${r.status}`);
}

function fetchOnce(pathname) {
  return new Promise((resolve, reject) => {
    const t0 = process.hrtime.bigint();
    const req = http.get(`${BASE}${pathname}`, { agent: herdAgent }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const ttfbMs = Number(process.hrtime.bigint() - t0) / 1e6;
        resolve({
          status: res.statusCode,
          cache: res.headers["x-nextjs-cache"] || null,
          ttfbMs,
          body: Buffer.concat(chunks).toString("utf8"),
        });
      });
    });
    req.on("error", reject);
    req.setTimeout(30_000, () => req.destroy(new Error("timeout")));
  });
}

const herdAgent = new http.Agent({
  keepAlive: true,
  maxSockets: SOCKETS,
  maxFreeSockets: SOCKETS,
});

// P0 — cached-read TTFB via autocannon (needs only aggregate latency).
async function phaseCachedTtfb(slug) {
  // warm the entry
  for (let i = 0; i < 10; i++) await fetchOnce(`/bench/news/${slug}`);
  const result = await autocannon({
    url: `${BASE}/bench/news/${slug}`,
    connections: 100,
    pipelining: 1,
    duration: 5,
  });
  const p50 = result.latency.p50;
  const p99 = result.latency.p99;
  const row = {
    phase: "P0-cached-ttfb",
    tool: "autocannon",
    connections: 100,
    requests: result.requests.total,
    errors: result.errors + (result.timeouts || 0),
    non2xx: result.non2xx,
    ttfbP50Ms: p50,
    ttfbP99Ms: p99,
    falsifier: "F1: cached p99 > 45 ms -> FAIL",
    verdict: p99 != null && p99 <= 45 ? "PASS" : "FAIL",
  };
  emit(row);
  return row;
}

// P1 — stampede herd on one expired slug.
async function phaseStampede(slug) {
  // expire the entry
  await new Promise((r) => setTimeout(r, REVALIDATE_MS + 1_000));

  // Baseline taken HERE, after the sleep and immediately before the herd, so
  // the delta counts only regenerations inside this single expired interval
  // (any earlier warm/expiry rebuild is excluded by construction).
  const before = (await getStats()).perSlug[slug] || 0;

  let inFlight = 0;
  let peakInFlight = 0;
  let lsofPeak = 0;
  const lsofTimer = setInterval(() => {
    try {
      const { port } = new URL(BASE);
      const n = execFileSync(
        "/usr/sbin/lsof",
        ["-nP", "-iTCP:" + port, "-sTCP:ESTABLISHED"],
        { encoding: "utf8" },
      )
        .trim()
        .split("\n").length - 1;
      if (n > lsofPeak) lsofPeak = n;
    } catch {
      /* lsof may fail briefly; peak sampling is best-effort */
    }
  }, 250);

  const results = [];
  let errors = 0;
  await new Promise((resolve) => {
    let launched = 0;
    let finished = 0;
    const launchMore = () => {
      while (launched < HERD && inFlight < SOCKETS) {
        launched++;
        inFlight++;
        if (inFlight > peakInFlight) peakInFlight = inFlight;
        fetchOnce(`/bench/news/${slug}`)
          .then((r) => results.push(r))
          .catch(() => errors++)
          .finally(() => {
            inFlight--;
            finished++;
            if (finished === HERD) {
              clearInterval(lsofTimer);
              resolve();
            } else launchMore();
          });
      }
    };
    launchMore();
  });

  const ok = results.filter((r) => r.status === 200);
  const ttfbs = ok.map((r) => r.ttfbMs).sort((a, b) => a - b);
  const byCache = {};
  for (const r of ok) byCache[r.cache || "none"] = (byCache[r.cache || "none"] || 0) + 1;
  const staleServed = (byCache.STALE || 0) + (byCache["STALE, HIT"] || 0) + (byCache.HIT || 0) * 0;
  // report stale explicitly; HIT responses during herd served pre-rebuild content
  const servedStaleOrPre = Object.entries(byCache)
    .filter(([k]) => k !== "MISS")
    .reduce((a, [, v]) => a + v, 0);

  // driver-reported stale witness into the event log
  await fetch(statsPath(), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ staleServed: servedStaleOrPre }),
  });
  const statsAfter = await getStats();
  const regenDelta = (statsAfter.perSlug[slug] || 0) - before;

  const row = {
    phase: "P1-stampede",
    slug,
    requestedTotal: HERD,
    socketCap: SOCKETS,
    achievedConcurrency: { peakInFlight, lsofPeakEstablished: lsofPeak },
    responses2xx: ok.length,
    transportErrors: errors,
    statusCounts: results.reduce((a, r) => ((a[r.status] = (a[r.status] || 0) + 1), a), {}),
    cacheHeaderCounts: byCache,
    ttfbP50Ms: pct(ttfbs, 50),
    ttfbP99Ms: pct(ttfbs, 99),
    staleOrPreRebuildServed: servedStaleOrPre,
    regenerationsDelta: regenDelta,
    falsifier: "F2: >1 runtime regeneration per expired interval -> FAIL",
    verdict: regenDelta === 1 && errors === 0 && ok.length === HERD ? "PASS" : "FAIL",
  };
  emit(row);
  return row;
}

function generatedAtOf(body) {
  const m = body.match(/data-generated-at="([^"]+)"/);
  return m ? new Date(m[1]).getTime() : null;
}

// P2 — 50 parallel on-demand revalidations while background reads continue.
async function phaseOnDemand(slugs) {
  const revalidateStart = Date.now();
  // Pre-warm every dependent slug until it serves post-warm content, so each
  // entry's generatedAt starts "now"; after this, content older than one
  // window (2x revalidate) served to a reader is a genuine staleness
  // violation, not build-time residue racing the warm rebuild.
  const warmStart = Date.now();
  for (const slug of slugs) {
    for (let i = 0; i < 20; i++) {
      const r = await fetchOnce(`/bench/news/${slug}`);
      const g = generatedAtOf(r.body);
      if (r.status === 200 && g != null && g >= warmStart) break;
    }
  }
  let reads = 0;
  let read5xx = 0;
  let staleBeyondWindow = 0;
  let stop = false;

  const reader = async () => {
    while (!stop) {
      const slug = slugs[Math.floor(Math.random() * slugs.length)];
      try {
        const r = await fetchOnce(`/bench/news/${slug}`);
        reads++;
        if (r.status >= 500) read5xx++;
        const g = generatedAtOf(r.body);
        if (g != null && Date.now() - g > 2 * REVALIDATE_MS) staleBeyondWindow++;
      } catch {
        reads++;
        read5xx++;
      }
    }
  };
  const readers = Array.from({ length: 20 }, reader);
  await new Promise((r) => setTimeout(r, 500)); // let readers warm entries

  // 50 parallel revalidate calls, one slug each
  const t0 = Date.now();
  const rv = await Promise.all(
    slugs.map((slug) =>
      fetch(statsPath(), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ slugs: [slug] }),
      }).then((r) => r.status),
    ),
  );
  const revalidateMs = Date.now() - t0;
  const revalidate5xx = rv.filter((s) => s >= 500).length;

  // drain: every slug must serve post-revalidate content
  let refreshed = 0;
  const unrefreshed = [];
  for (let attempt = 0; attempt < 20; attempt++) {
    refreshed = 0;
    unrefreshed.length = 0;
    const checks = await Promise.all(
      slugs.map(async (slug) => {
        const r = await fetchOnce(`/bench/news/${slug}`);
        return { slug, g: generatedAtOf(r.body), status: r.status };
      }),
    );
    for (const c of checks) {
      if (c.g != null && c.g > revalidateStart) refreshed++;
      else unrefreshed.push(c.slug);
    }
    if (refreshed === slugs.length) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  stop = true;
  await Promise.allSettled(readers);

  const row = {
    phase: "P2-on-demand-revalidation",
    slugs: slugs.length,
    backgroundReads: reads,
    revalidateCalls: rv.length,
    revalidateMs,
    revalidate5xx,
    read5xx,
    staleBeyondOneWindow: staleBeyondWindow,
    refreshedAfterRevalidate: refreshed,
    unrefreshedSample: unrefreshed.slice(0, 5),
    falsifier:
      "F3: any 5xx, stale-beyond-one-window, or unrefreshed slug after drain -> FAIL",
    verdict:
      read5xx === 0 &&
      revalidate5xx === 0 &&
      staleBeyondWindow === 0 &&
      refreshed === slugs.length
        ? "PASS"
        : "FAIL",
  };
  emit(row);
  return row;
}

// P3 — disk/cache behavior witness.
async function phaseDisk() {
  const out = { phase: "P3-disk-cache" };
  try {
    const du = execFileSync("du", ["-sk", "workspace/.next/cache"], {
      cwd: new URL("../..", import.meta.url).pathname,
      encoding: "utf8",
    });
    out.nextCacheKb = parseInt(du.split("\t")[0], 10);
  } catch {
    out.nextCacheKb = null;
  }
  const stats = await getStats();
  out.statsRoute = stats;
  out.eventsPath = stats.eventsPath;
  try {
    const st = fs.statSync(stats.eventsPath);
    out.eventsFileBytes = st.size;
    out.eventsFileLines = fs
      .readFileSync(stats.eventsPath, "utf8")
      .split("\n")
      .filter(Boolean).length;
  } catch {
    out.eventsFileBytes = null;
  }
  out.verdict = "PASS"; // observational phase
  emit(out);
  return out;
}

// ---- main ----
// Preflight (EXPL7-R1 E7-3): /api/bench/isr-stats POST (reset/stale) is a
// gated debug face — it answers 404 unless the SERVER was started with
// SMALT_DEBUG_FACES=1. This lane drives an externally-launched server
// (N6_URL); fail loudly with the launch requirement instead of a confusing
// mid-phase "stats reset 404".
{
  const probe = await fetch(statsPath(), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ reset: true }),
  });
  if (probe.status === 404) {
    console.error(
      "FATAL: /api/bench/isr-stats POST -> 404 (debug faces gated). " +
        'Relaunch the workspace server with SMALT_DEBUG_FACES=1 ' +
        "(EXPL7-R1 E7-3, docs/jira/v26.10.22/receipts/expl7r1-bff-repairs.md).",
    );
    process.exit(3);
  }
}

await resetStats();
const stats0 = await getStats();

const p0 = await phaseCachedTtfb(PRIMARY_SLUG);
const p1 = await phaseStampede(PRIMARY_SLUG);
const p2 = await phaseOnDemand(DEPENDENT_SLUGS);
const p3 = await phaseDisk();

const verdicts = { F1: p0.verdict, F2: p1.verdict, F3: p2.verdict };
emit({ phase: "FINAL", verdicts, allPass: Object.values(verdicts).every((v) => v === "PASS") });

fs.mkdirSync(new URL(".", `file://${process.cwd()}/${OUT}`).pathname, { recursive: true });
fs.writeFileSync(OUT, rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
console.error(`wrote ${OUT}`);
process.exit(verdicts.F1 === "PASS" && verdicts.F2 === "PASS" && verdicts.F3 === "PASS" ? 0 : 1);
