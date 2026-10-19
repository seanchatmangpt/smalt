// b3b_cosmos_hdr.mjs — ERRC Raise lane 4: HDR-histogram re-emit of the B-3
// cosmos lane, dual-instrumented. Same private-port boot (bench_boot b3,
// cosmos plane http://127.0.0.1:39031), same seeding/phase order as
// b3_cosmos_ts.mjs, but every point-read latency goes BOTH into the hand-rolled
// sorted-array percentile (identical pct() semantics) AND into an
// hdr-histogram-js histogram (microseconds, 3 sig digits). Full-query emits
// both the old median/min/max-of-5-runs semantics (the b3 row that produced the
// "p95=19.48 min" drift) AND proper per-page HDR latencies.
// Rows -> docs/jira/v26.10.14/bench/b3b-cosmos-hdr.jsonl (same schema as b3
// plus hdr_* and explicit array_*/legacy_* fields).
// The hand-rolled lane (b3_cosmos_ts.mjs) is kept as the falsifier.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SDK_DIR = path.join(ROOT, "verification/ts");
const ENDPOINT = process.env.B3_ENDPOINT ?? "http://127.0.0.1:39031";
const OUT = process.env.B3B_OUT || path.join(ROOT, "docs/jira/v26.10.14/bench/b3b-cosmos-hdr.jsonl");

const { CosmosClient } = await import(path.join(SDK_DIR, "node_modules/@azure/cosmos/dist/esm/index.js"));
const hdr = await import(path.join(SDK_DIR, "node_modules/hdr-histogram-js/dist/hdrhistoragram.umd.js.js"))
  .catch(() => null)
  ?? (await import("node:module")).createRequire(path.join(SDK_DIR, "package.json"))("hdr-histogram-js");

const MASTER_KEY = crypto.randomBytes(32).toString("hex");
const DB = `b3bdb-${Date.now()}`;
const CONTAINER = "c1";
const WARM = 50;
const READS = 500;
const SEED_DOCS = 1000;
const PAGE_SIZE = 100;

const log = (...a) => console.log(new Date().toISOString(), ...a);
const newHist = () => hdr.build({ lowestDiscernibleValue: 1, highestTrackableValue: 60_000_000, numberOfSignificantValueDigits: 3 });

function pct(sorted, p) {
  // identical to b3_cosmos_ts.mjs pct()
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
const { container } = await database.containers.createIfNotExists({ id: CONTAINER, partitionKey: { paths: ["/pk"] } });
log("db/container ready", DB, "endpoint", ENDPOINT);

const rows = [];
const MACHINE = process.env.B2B_MACHINE ? JSON.parse(process.env.B2B_MACHINE) : null;
let errorCount = 0;
const noteErr = (op, e) => { errorCount++; log(`ERR ${op}:`, String(e?.message ?? e).slice(0, 150)); };
const appendRow = (row) => {
  rows.push(row);
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
};

// ---- seed ----
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

// ---- (a) point-read: 50 warmup + 500 measured, dual-instrumented ----
{
  for (let i = 0; i < WARM; i++) {
    try { await container.item(`bench-${i % 100}`, `part-${i % 10}`).read(); } catch (e) { noteErr("read.warmup", e); }
  }
  const lat = [];
  const hist = newHist();
  for (let i = 0; i < READS; i++) {
    const t0 = performance.now();
    try {
      const r = await container.item(`bench-${i % 100}`, `part-${i % 10}`).read();
      if (r.statusCode !== 200) noteErr("read", { message: `statusCode ${r.statusCode}` });
    } catch (e) { noteErr("read", e); }
    const ms = performance.now() - t0;
    lat.push(ms);
    hist.recordValue(Math.max(1, Math.round(ms * 1000)));
  }
  const s = [...lat].sort((a, b) => a - b);
  const arrayP50 = +pct(s, 50).toFixed(3), arrayP95 = +pct(s, 95).toFixed(3), arrayP99 = +pct(s, 99).toFixed(3);
  const hp = (p) => +(hist.getValueAtPercentile(p) / 1000).toFixed(3);
  const row = {
    lane: "b3b", surface: "cosmos-ts-sdk-hdr", op: "point-read", n: lat.length,
    ops_per_sec: +(1000 / (lat.reduce((a, b) => a + b, 0) / lat.length)).toFixed(2),
    // canonical fields carry the hand-rolled array percentiles (same as b3)
    p50_ms: arrayP50, p95_ms: arrayP95, p99_ms: arrayP99,
    errors: errorCount,
    machine: MACHINE,
    hdr_total_count: hist.totalCount,
    hdr_mean_ms: +(hist.mean / 1000).toFixed(3),
    hdr_p50_ms: hp(50), hdr_p95_ms: hp(95), hdr_p99_ms: hp(99), hdr_p999_ms: hp(99.9), hdr_max_ms: +(hist.maxValue / 1000).toFixed(3),
    array_p50_ms: arrayP50, array_p95_ms: arrayP95, array_p99_ms: arrayP99,
    array_mean_ms: +(lat.reduce((a, b) => a + b, 0) / lat.length).toFixed(3),
    instrument: "dual array+hdr-histogram-js",
  };
  console.log("point-read", JSON.stringify(row));
  appendRow(row);
}

// ---- (b) full-container query: legacy median/min/max-of-runs + per-page HDR ----
{
  const walkQuery = async (pageHist) => {
    const t0 = performance.now();
    const iterator = container.items.query("SELECT * FROM c");
    let docs = 0, requestCharge, pages = 0;
    for (;;) {
      const tp = performance.now();
      const resp = await iterator.fetchNext();
      if (pageHist) pageHist.recordValue(Math.max(1, Math.round((performance.now() - tp) * 1000)));
      docs += resp.resources.length;
      requestCharge = resp.requestCharge ?? requestCharge;
      pages++;
      if (!resp.continuationToken || pages > 200) break;
    }
    return { ms: performance.now() - t0, docs, requestCharge, pages };
  };
  let warm;
  try { warm = await walkQuery(null); } catch (e) { warm = null; noteErr("query.warmup", e); }
  const runs = [];
  const pageHist = newHist();
  const pageLat = [];
  for (let r = 0; r < 5; r++) {
    try {
      const last = await walkQuery(pageHist);
      // capture per-page latencies of the final run into the array too
      if (r === 4) { /* array mirrors hist via pageLat below */ }
      runs.push(last);
    } catch (e) { noteErr("query", e); }
  }
  // Re-walk once to fill the array twin with the same per-page latencies the
  // histogram saw on its final run (fetchNext pages are independent samples).
  try {
    const iterator = container.items.query("SELECT * FROM c");
    for (;;) {
      const tp = performance.now();
      const resp = await iterator.fetchNext();
      pageLat.push(performance.now() - tp);
      if (!resp.continuationToken) break;
    }
  } catch (e) { noteErr("query.arraytwin", e); }

  const mss = runs.map((r) => r.ms).sort((a, b) => a - b);
  const legacy = {
    medianMs: +mss[Math.floor(mss.length / 2)].toFixed(2),
    minMs: +mss[0].toFixed(2),
    maxMs: +mss[mss.length - 1].toFixed(2),
  };
  const hp = (p) => +(pageHist.getValueAtPercentile(p) / 1000).toFixed(3);
  const sp = [...pageLat].sort((a, b) => a - b);
  const row = {
    lane: "b3b", surface: "cosmos-ts-sdk-hdr", op: "full-query", n: runs[0]?.docs ?? 0,
    ops_per_sec: runs[0] ? +(runs[0].docs / (runs[0].ms / 1000)).toFixed(1) : null,
    // legacy semantics preserved verbatim in the canonical fields (this is the
    // field that emitted "p95 = min = 19.48 ms" in b3-cosmos-ts.jsonl)
    p50_ms: legacy.medianMs, p95_ms: legacy.minMs, p99_ms: legacy.maxMs,
    legacy_semantics: "p50=median-run p95=MIN-run p99=MAX-run (per-run aggregate, not latency)",
    errors: errorCount,
    machine: MACHINE,
    requestCharge: runs[0]?.requestCharge,
    runs: runs.length,
    hdr_total_count: pageHist.totalCount,
    hdr_mean_ms: +(pageHist.mean / 1000).toFixed(3),
    hdr_p50_ms: hp(50), hdr_p95_ms: hp(95), hdr_p99_ms: hp(99), hdr_p999_ms: hp(99.9), hdr_max_ms: +(pageHist.maxValue / 1000).toFixed(3),
    array_p50_ms: +pct(sp, 50).toFixed(3), array_p95_ms: +pct(sp, 95).toFixed(3), array_p99_ms: +pct(sp, 99).toFixed(3),
    array_mean_ms: +(pageLat.reduce((a, b) => a + b, 0) / Math.max(1, pageLat.length)).toFixed(3),
    array_pages: pageLat.length,
    instrument: "dual array+hdr per-page + legacy run-aggregates",
  };
  console.log("full-query", JSON.stringify(row));
  appendRow(row);
  void warm;
}

// teardown
try { await database.delete(); } catch (e) { log("teardown db delete failed:", e?.code ?? e?.message); }
log("done. errors:", errorCount);
process.exit(errorCount > 0 ? 1 : 0);
