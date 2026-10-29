// PB-6 wire leg: the 5-step settlement walk through the @azure/cosmos SDK over
// the TLS twin (real TLS + HTTP machinery). Steps mirror the native POWL leg
// in pb6_dual_boundary.exs step-for-step:
//   1-lease    items.create           (lease doc, 201, capture etag)
//   2-validate item.read -> etag == lease etag
//   3-cas      item.replace {accessCondition:{type:"IfMatch",condition:etag}}   (If-Match CAS)
//   4-seal     item.replace {accessCondition:{...etag2}}  (seal body, second CAS)
//   5-observe  item.read -> state == "seal"   (settlement visible)
// Per-step wall time via client timestamps (performance.now() around each
// SDK call). Emits one JSON stats object to PB6_WIRE_OUT (or stdout).
//
// Auth note (honest): this leg rides anonymous auth mode like the b3 lane —
// the enforce-mode resource-token path is a separate divergence (SDK 4.10.1
// percent-encodes the type=resource header; see receipt).
import fs from "node:fs";

const TLS = process.env.PB6_TLS ?? "https://localhost:39174";
const OUT = process.env.PB6_WIRE_OUT ?? new URL("../../tmp/bench/pb6-wire-steps.json", import.meta.url).pathname;
const SDK = new URL("../../verification/ts/node_modules/@azure/cosmos", import.meta.url).pathname;
const WARM = Number(process.env.PB6_WIRE_WARM ?? 20);
const ITERS = Number(process.env.PB6_WIRE_ITERS ?? 300);

const log = (...a) => console.error("[pb6-wire]", ...a);

const { CosmosClient } = await import(`${SDK}/dist/esm/index.js`);
const sdkVersion = JSON.parse(fs.readFileSync(`${SDK}/package.json`, "utf8")).version;

const client = new CosmosClient({
  endpoint: TLS,
  key: crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", ""),
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});

const DB = `pb6w-${Date.now()}`;
const { database } = await client.databases.createIfNotExists({ id: DB });
const { container } = await database.containers.createIfNotExists({
  id: "c1", partitionKey: { paths: ["/pk"] },
});
log(`db/container ready ${DB} endpoint=${TLS} sdk=${sdkVersion}`);

const stepMs = { "1-lease": [], "2-validate": [], "3-cas": [], "4-seal": [], "5-observe": [] };
let errors = 0;

const timed = async (name, fn) => {
  const t0 = performance.now();
  try {
    return await fn();
  } catch (e) {
    errors++;
    log(`ERROR at ${name}: ${e.code ?? ""} ${String(e.message).slice(0, 200)}`);
    throw e;
  } finally {
    stepMs[name].push(performance.now() - t0);
  }
};

async function walk(i) {
  const id = `d${i}`;
  const pk = "pb6";
  const cont = container.item(id, pk);

  const lease = await timed("1-lease", () =>
    container.items.create({ id, pk, state: "lease", v: i }),
  );
  const leaseEtag = lease.resource._etag;

  await timed("2-validate", async () => {
    const got = await cont.read();
    if (got.resource._etag !== leaseEtag) throw new Error("validate: etag mismatch");
  });

  const cas = await timed("3-cas", () =>
    cont.replace({ id, pk, state: "cas", v: i }, { accessCondition: { type: "IfMatch", condition: leaseEtag } }),
  );

  await timed("4-seal", () =>
    cont.replace({ id, pk, state: "seal", sealSig: `pb6-${i}` }, { accessCondition: { type: "IfMatch", condition: cas.resource._etag } }),
  );

  await timed("5-observe", async () => {
    const got = await cont.read();
    if (got.resource.state !== "seal") throw new Error("observe: settlement not visible");
  });
}

log(`warmup ${WARM}`);
for (let i = 0; i < WARM; i++) await walk(-1 - i);

log(`measured ${ITERS}`);
for (let i = 0; i < ITERS; i++) {
  await walk(i);
}

const stats = (arr) => {
  const v = [...arr].sort((a, b) => a - b);
  const p = (q) => v[Math.min(v.length - 1, Math.ceil((q / 100) * v.length) - 1)] ?? 0;
  const mean = v.reduce((s, x) => s + x, 0) / (v.length || 1);
  return { mean_ms: mean, p50_ms: p(50), p95_ms: p(95), p99_ms: p(99) };
};

const out = {
  leg: "wire",
  sdk: sdkVersion,
  endpoint: TLS,
  n: ITERS,
  errors,
  steps: Object.fromEntries(Object.entries(stepMs).map(([k, v]) => [k, stats(v)])),
};
fs.writeFileSync(OUT, JSON.stringify(out, null, 2));
log(`wrote ${OUT} errors=${errors}`);
