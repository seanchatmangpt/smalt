// PB-1 lane, SDK leg — comparable @azure/cosmos CAS over the TLS twin
// (bench_boot lane b1 port block 39010..39015; atls = 39014, the 9444 twin seat).
// Real SDK from verification/ts node_modules. Retry options left at DEFAULT
// (429 backoff active; 412 PreconditionFailed is surfaced to the caller by the
// SDK — measured, see receipt). Contention injected driver-side: R forced
// stale-etag replace attempts (412) then one CAS match, same injection shape
// as the native leg. Loud SKIP (exit 3) on substrate down — never restarts.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SDK_DIR = path.join(ROOT, "verification/ts");
const ATLS = process.env.PB1_ATLS ?? "39014";
const EGRESS = process.env.PB1_EGRESS ?? "39011";
const ENDPOINT = `https://127.0.0.1:${ATLS}`;
const RATES = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
const WAVES = 150;
const WARMUP = 20;
const FANOUT = 4;

const log = (...a) => console.log(new Date().toISOString(), ...a);

const { CosmosClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/cosmos/dist/commonjs/index.js")
);

// ---- substrate liveness: loud SKIP, never restart -------------------------
async function probe() {
  try {
    const res = await fetch(`http://127.0.0.1:${EGRESS}/dbs`, { method: "GET" });
    if (!res.ok && res.status !== 404) throw new Error(`status ${res.status}`);
    log("substrate alive (egress data plane answered)");
  } catch (e) {
    console.error(`PB1-SKIP: substrate down (${String(e).slice(0, 120)})`);
    process.exit(3);
  }
}
await probe();

const client = new CosmosClient({
  endpoint: ENDPOINT,
  key: crypto.randomBytes(32).toString("hex"),
  // DEFAULT retry options — resourceThrottleRetryPolicy backoff on 429 stays
  // active (b3 lane disabled retries; PB-1 measures the retry tax).
  connectionPolicy: { enableEndpointsDiscovery: false },
});

const sdkVersion = JSON.parse(
  fs.readFileSync(path.join(SDK_DIR, "node_modules/@azure/cosmos/package.json"), "utf8")
).version;
log("meta", JSON.stringify({ sdk: sdkVersion, node: process.version, endpoint: ENDPOINT }));

let conflicts = 0; // observed 412s (injected, recovered)
let unexpected = 0; // real errors (non-412, non-injection)
let injectionFailures = 0; // stale etag ACCEPTED by the surface (If-Match ignored)

// one settlement: R stale-etag attempts (412) then CAS match (200)
async function settle(item, doc, r) {
  let etag;
  if (r === 0) {
    ({ etag } = await item.read());
  } else {
    // first stale attempt: guaranteed 412 carrying current doc state
    try {
      await item.replace({ ...doc, v: 1 }, { accessCondition: { type: "IfMatch", condition: "pb1-stale-seed" } });
      throw new Error("contention-injection-failed: stale etag was accepted");
    } catch (e) {
      if (e.message.startsWith("contention-injection-failed")) { injectionFailures++; throw e; }
      if (e?.code !== 412) throw e;
      conflicts++;
    }
    // recover current etag the way a real CAS loser does: read it back
    ({ etag } = await item.read());

    // remaining R-1 forced retries, same shape
    for (let i = 2; i <= r; i++) {
      try {
        await item.replace({ ...doc, v: 1 }, { accessCondition: { type: "IfMatch", condition: `pb1-stale-${i}` } });
        throw new Error("contention-injection-failed: stale etag was accepted");
      } catch (e) {
        if (e.message.startsWith("contention-injection-failed")) { injectionFailures++; throw e; }
        if (e?.code !== 412) throw e;
        conflicts++;
      }
      ({ etag } = await item.read());
    }
  }
  await item.replace({ ...doc, v: 2 }, { accessCondition: { type: "IfMatch", condition: etag } });
}

// one orchestration: FANOUT concurrent settlements (mirrors the native leg's
// 4-transition PartialOrder frontier)
async function orchestration(container, r) {
  const docs = Array.from({ length: FANOUT }, (_, k) => ({
    id: `doc${r}-${k + 1}`,
    pk: `pb1-${r}-${k + 1}`,
    v: 0,
    payload: "x".repeat(256),
  }));
  await Promise.all(
    docs.map(async (doc) => {
      const item = container.item(doc.id, doc.pk);
      try {
        await container.items.create(doc);
      } catch (e) {
        if (e?.code !== 409) throw e; // fresh db per rate: 409 impossible, but typed
      }
      await settle(item, doc, r);
    })
  );
}

for (const r of RATES) {
  const dbname = `pb1db-${Date.now()}-r${r}`;
  const { database: db2 } = await client.databases.createIfNotExists({ id: dbname });
  const { container: c2 } = await db2.containers.createIfNotExists({
    id: "c1",
    partitionKey: { paths: ["/pk"] },
  });

  const walls = [];
  const errs = [];
  let rateUnexpected = 0;
  let rateInjFail = 0;

  for (let w = -WARMUP; w < WAVES; w++) {
    const t0 = performance.now();
    try {
      await orchestration(c2, r);
      if (w >= 0) walls.push(performance.now() - t0);
    } catch (e) {
      if (e.message.startsWith("contention-injection-failed")) { rateInjFail++; injectionFailures++; }
      else { unexpected++; rateUnexpected++; errs.push(String(e?.code ?? e?.message ?? e).slice(0, 80)); }
      if (w >= 0) walls.push(performance.now() - t0);
    }
  }

  const sorted = [...walls].sort((a, b) => a - b);
  const p = (q) => sorted[Math.min(sorted.length - 1, Math.round((q / 100) * (sorted.length - 1)))];
  const total = walls.reduce((a, b) => a + b, 0);
  const row = {
    lane: "pb1",
    surface: "cosmos-sdk-tls-twin",
    op: `settle_r${r}`,
    contention_pct: r * 10,
    retries_forced: r,
    n: WAVES,
    ops_per_sec: +(WAVES / (total / 1000)).toFixed(2),
    p50_ms: +p(50).toFixed(3),
    p95_ms: +p(95).toFixed(3),
    p99_ms: +p(99).toFixed(3),
    errors: rateUnexpected,
    injection_failures: rateInjFail,
    note: rateInjFail > 0 ? "IF-MATCH-IGNORED surface divergence (KD/GAP pending)" : undefined,
  };
  console.log("PB1ROW " + JSON.stringify(row));
  if (errs.length) log(`rate r=${r} error samples:`, [...new Set(errs)].slice(0, 5));

  await client.database(dbname).delete();
}
console.log(`PB1SDK-DONE conflicts=${conflicts} unexpected_errors=${unexpected}`);
