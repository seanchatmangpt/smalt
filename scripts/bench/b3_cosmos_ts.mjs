// B-3 lane: cosmos latency + pagination throughput via real @azure/cosmos SDK.
// Self-booted private substrate (lib.sh bench_boot b3), cosmos plane
// http://127.0.0.1:39031 (lane b3 port block 39030..39035, egress = base+1).
//
// Phase order (coordinator directive 2026-10-15): point-read, full query, and
// continuation walk FIRST; upsert throughput LAST with a hard doc cap so the
// post-upsert full query cannot hang on a huge container (total docs <= 2k).
// Measures: point-read latency, full-container query, continuation walk,
// create-only upsert throughput (KD-36: upsert-of-existing 409s -> create-only).
// SQL whitelist: `SELECT * FROM c` only.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SDK_DIR = path.join(ROOT, "verification/ts");
const ENDPOINT = process.env.B3_ENDPOINT ?? "http://127.0.0.1:39031";
const OUT = process.env.B3_OUT ?? path.join(ROOT, "docs/jira/v26.10.14/bench/b3-cosmos-ts.jsonl");

// resolve SDK from verification/ts/node_modules (no root install): real ESM build
const { CosmosClient } = await import(path.join(SDK_DIR, "node_modules/@azure/cosmos/dist/esm/index.js"));

const MASTER_KEY = crypto.randomBytes(32).toString("hex");
const DB = `b3db-${Date.now()}`;
const CONTAINER = "c1";
const WARM = 50;
const READS = 500;
const THROUGHPUT_WINDOW_MS = 30_000;
const SEED_DOCS = 1000;          // docs present before the query phases
const MAX_UPSERT_DOCS = 1000;    // hard cap: upsert phase stops here (total <= 2k)
const PAGE_SIZE = 100;

const log = (...a) => console.log(new Date().toISOString(), ...a);

// canonical result rows appended to OUT; event log goes to stdout only.
const rows = [];
const SUMMARY = (op, n, opsPerSec, p50, p95, p99, errors) => {
  console.log(`SUMMARY ${op} ${n} ${opsPerSec} ${p50} ${p95} ${p99} ${errors}`);
  rows.push({ op, n, opsPerSec, p50, p95, p99, errors: Number(errors) });
};

function pct(sorted, p) {
  const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, i)];
}

const client = new CosmosClient({
  endpoint: ENDPOINT,
  key: MASTER_KEY,
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});

const { database } = await client.databases.createIfNotExists({ id: DB });
const { container } = await database.containers.createIfNotExists({
  id: CONTAINER, partitionKey: { paths: ["/pk"] },
});
log("db/container ready", DB, "endpoint", ENDPOINT);
const sdkVersion = JSON.parse(fs.readFileSync(path.join(SDK_DIR, "node_modules/@azure/cosmos/package.json"), "utf8")).version;
log("meta", JSON.stringify({ sdk: sdkVersion, node: process.version }));

const errors = [];
let errorCount = 0;
const noteErr = (op, e) => { errorCount++; errors.push({ op, code: e?.code, body: JSON.stringify(e?.body ?? "").slice(0, 200), msg: String(e?.message ?? "").slice(0, 150) }); };

// ---- seed N docs (sequential creates) ----
async function seed(n, prefix, pkBase) {
  const t0 = performance.now();
  let ok = 0;
  for (let i = 0; i < n; i++) {
    try {
      await container.items.create({ id: `${prefix}${i}`, pk: `${pkBase}${i % 10}`, i, payload: "x".repeat(256) });
      ok++;
    } catch (e) { noteErr("seed", e); }
  }
  return { n, ok, ms: performance.now() - t0 };
}

log(`seeding ${SEED_DOCS} docs...`);
const seedR = await seed(SEED_DOCS, "bench-", "part-");
log(`seeded ${seedR.ok}/${seedR.n} in ${seedR.ms.toFixed(0)}ms`);

// ---- (a) point-read latency: >=500 reads + 50 warmup ----
{
  for (let i = 0; i < WARM; i++) {
    try { await container.item(`bench-${i % 100}`, `part-${i % 10}`).read(); } catch (e) { noteErr("read.warmup", e); }
  }
  const lat = [];
  for (let i = 0; i < READS; i++) {
    const t0 = performance.now();
    try {
      const r = await container.item(`bench-${i % 100}`, `part-${i % 10}`).read();
      if (r.statusCode !== 200) noteErr("read", { code: r.statusCode });
    } catch (e) { noteErr("read", e); }
    lat.push(performance.now() - t0);
  }
  const s = [...lat].sort((a, b) => a - b);
  const p50 = +pct(s, 50).toFixed(3), p95 = +pct(s, 95).toFixed(3), p99 = +pct(s, 99).toFixed(3);
  const stats = {
    n: lat.length, p50, p95, p99, min: +s[0].toFixed(3), max: +s[s.length - 1].toFixed(3),
    meanMs: +(lat.reduce((a, b) => a + b, 0) / lat.length).toFixed(3),
  };
  log("point-read", JSON.stringify(stats));
  SUMMARY("point-read", lat.length, +(1000 / stats.meanMs).toFixed(2), p50, p95, p99, errorCount);
}

// ---- (b) full-container query: SELECT * FROM c over SEED_DOCS docs ----
{
  const walkQuery = async () => {
    const t0 = performance.now();
    const iterator = container.items.query("SELECT * FROM c");
    let docs = 0, requestCharge, pages = 0;
    for (;;) {
      const resp = await iterator.fetchNext();
      docs += resp.resources.length;
      requestCharge = resp.requestCharge ?? requestCharge;
      pages++;
      if (!resp.continuationToken || pages > 200) break;
    }
    return { ms: performance.now() - t0, docs, requestCharge, pages };
  };
  let warm;
  try { warm = await walkQuery(); } catch (e) { warm = null; noteErr("query.warmup", e); }
  const runs = [];
  for (let r = 0; r < 5; r++) {
    try { runs.push(await walkQuery()); } catch (e) { noteErr("query", e); }
  }
  const mss = runs.map((r) => r.ms).sort((a, b) => a - b);
  const stats = {
    runs: runs.length, docs: runs[0]?.docs ?? 0,
    medianMs: +mss[Math.floor(mss.length / 2)].toFixed(2), minMs: +mss[0].toFixed(2), maxMs: +mss[mss.length - 1].toFixed(2),
    requestCharge: runs[0]?.requestCharge,
    docsPerSec: runs[0] ? +(runs[0].docs / (runs[0].ms / 1000)).toFixed(1) : null,
  };
  log("full-container query", JSON.stringify(stats));
  if (runs.length) SUMMARY("full-query", stats.docs, stats.docsPerSec, stats.medianMs, stats.minMs, stats.maxMs, errorCount);
}

// ---- (c) continuation walk: pages of 100 over seeded docs ----
{
  const iterator = container.items.query("SELECT * FROM c", { maxItemCount: PAGE_SIZE });
  const pages = [];
  let page = 0;
  const t0 = performance.now();
  for (;;) {
    const tp = performance.now();
    try {
      const resp = await iterator.fetchNext();
      page++;
      pages.push({ page, docs: resp.resources.length, ms: +(performance.now() - tp).toFixed(2) });
      if (!resp.continuationToken) break;
    } catch (e) { noteErr("continuation", e); break; }
  }
  const wall = performance.now() - t0;
  const totalDocs = pages.reduce((a, p) => a + p.docs, 0);
  const pms = pages.map((p) => p.ms).sort((a, b) => a - b);
  const stats = { pages: page, pageSize: PAGE_SIZE, totalDocs, wallMs: +wall.toFixed(1), pagesPerSec: +(page / (wall / 1000)).toFixed(2), pageMsMedian: +pms[Math.floor(pms.length / 2)].toFixed(2), pageMsMax: +pms[pms.length - 1].toFixed(2) };
  log("continuation walk", JSON.stringify(stats));
  SUMMARY("continuation-walk", totalDocs, stats.pagesPerSec, stats.pageMsMedian, stats.pageMsMax, stats.pageMsMax, errorCount);
}

// ---- (d) create-only upsert throughput, LAST, hard-capped (window OR doc cap) ----
{
  // small warmup so SDK caches route/etc
  for (let i = 0; i < WARM; i++) {
    try { await container.items.upsert({ id: `ups-warm-${i}`, pk: "ups", i }); } catch (e) { noteErr("upsert.warmup", e); }
  }
  const start = performance.now();
  let ops = 0;
  let hitCap = false;
  do {
    try { await container.items.upsert({ id: `ups-${ops}`, pk: "ups", ops }); ops++; }
    catch (e) {
      noteErr("upsert", e);
      if (e?.code === 409) { log("KD-36 upsert-of-existing 409 observed (unexpected: id was fresh)"); }
    }
    if (ops >= MAX_UPSERT_DOCS) { hitCap = true; break; }
  } while (performance.now() - start < THROUGHPUT_WINDOW_MS);
  const wall = performance.now() - start;
  const stats = { windowMs: +wall.toFixed(0), ops, opsPerSec: +(ops / (wall / 1000)).toFixed(2), cappedBy: hitCap ? "MAX_UPSERT_DOCS" : "window" };
  log("upsert throughput", JSON.stringify(stats));
  SUMMARY("upsert-create-only", ops, stats.opsPerSec, +(wall / ops).toFixed(3), +(wall / ops).toFixed(3), +(wall / ops).toFixed(3), errorCount);
}

log("errors total:", errorCount, errors.length ? JSON.stringify(errors.slice(0, 5)) : "(none)");
if (rows.length) {
  console.log("ROWS " + JSON.stringify(rows));
}

// teardown: this db only; the substrate process is lane-private
try { await database.delete(); } catch (e) { log("teardown db delete failed:", e?.code ?? e?.message); }
log("done. errors:", errorCount);
process.exit(errorCount > 0 ? 1 : 0);
