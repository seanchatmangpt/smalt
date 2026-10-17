// LC-1 lane: 8-hop Cloud-Chain Tax Pipeline lifecycle harness.
//
// N=200 complete lifecycle cycles (~1600 API ops) against a self-booted smalt
// substrate (private ports 39640-39645, MIX_ENV=test, anonymous auth) plus a
// `next start` workspace server (port 39650) for the APIM nearest-analog hop.
//
// Hop mapping (honest, labeled at emit time):
//   1 Entra      -> smalt STS   POST /oauth2/v2.0/token                 [REAL]
//   2 APIM       -> workspace Next /api/v1/ingest handler, token-bucket
//                  rate limiter = nearest-analog gateway policy [NEAREST_ANALOG]
//   3 Cosmos CAS -> @azure/cosmos etag (ifMatchEtag) replace             [REAL]
//   4 KV/HSM sign-> KV crypto sign POST /keys/:name/sign RS256           [REAL]
//   5 EH ingress -> @azure/event-hubs producer (AMQP), 1 event/send,
//                  paced — the directive's REST /messages does NOT exist   [SDK]
//   6 Blob append-> NO append surface in smalt; block-blob PUT to a
//                  compliance container per cycle                  [PUT-journal]
//   7 Cognitive Search -> NO smalt surface; nearest-analog Resource Graph
//                  query over seeded storage accounts      [NEAREST_ANALOG]
//   8 Sentinel   -> DCR ingest + synchronous RYW KQL read-back
//                  (where TxId == ... | take 1), row verified      [REAL]
//
// Emits JSONL rows (bench_emit schema + hop extras) to
// docs/jira/v26.10.14/bench/lifecycle-8hop.jsonl and prints a summary table.
//
// Run:
//   node scripts/bench/lifecycle_harness.mjs
//
// Exit: 0 on success (any number of per-op errors), 1 on fatal setup failure.
// Local substrate vault uses a self-signed cert (arm_tls port) — this harness
// talks only to 127.0.0.1, so the check is disabled here, nowhere else.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SDK = path.join(REPO, "test/sdk-full");
const JSONL = path.join(REPO, "docs/jira/v26.10.14/bench/lifecycle-8hop.jsonl");
const LANE = "lc1";

const ARM = process.env.LC1_ARM ?? "http://127.0.0.1:39640";
const EGRESS = process.env.LC1_EGRESS ?? "http://127.0.0.1:39641";
const AMQP_PORT = 39642, EH_PORT = 39643, VAULT_TLS = 39644;
const VAULT = `https://127.0.0.1:${VAULT_TLS}`;
const NEXT = process.env.LC1_NEXT ?? "http://127.0.0.1:39650";
const N_CYCLES = Number(process.env.LC1_N ?? 200);

const EHUB = "lc1-hub";
const ACCOUNT = "smaltacct", ACCOUNT_KEY = "smaltacct-key";
const TX_CONTAINER = "compliance-lc1";

const require2 = createRequire(path.join(SDK, "package.json"));
const { CosmosClient } = await import(path.join(SDK, "node_modules/@azure/cosmos/dist/esm/index.js"));
const { BlobServiceClient, StorageSharedKeyCredential } = await import(
  path.join(SDK, "node_modules/@azure/storage-blob/dist/esm/index.js"));
const { EventHubProducerClient } = createRequire(path.join(SDK, "package.json"))("@azure/event-hubs");

const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- JSONL emit (bench_emit schema + extras) ----
const MACHINE = {
  cpu: os.cpus()[0]?.model ?? "unknown",
  cores: os.cpus().length,
  ram_gb: Math.round(os.totalmem() / 1024 ** 3),
  node: process.version,
  darwin: `${os.type()} ${os.release()}`,
};
function emit(surface, op, n, opsPerSec, p50, p95, p99, errors, extra = {}) {
  const row = {
    lane: LANE, surface, op, n,
    ops_per_sec: +Number(opsPerSec).toFixed(2),
    p50_ms: +p50.toFixed(3), p95_ms: +p95.toFixed(3), p99_ms: +p99.toFixed(3),
    errors, machine: MACHINE, ...extra,
  };
  fs.appendFileSync(JSONL, JSON.stringify(row) + "\n");
  log(`EMIT ${surface}/${op} n=${n} ${row.ops_per_sec}/s p50=${row.p50_ms} p95=${row.p95_ms} p99=${row.p99_ms} err=${errors}`);
}
function pct(v, p) {
  const s = [...v].sort((a, b) => a - b);
  return s[Math.round((p / 100) * (s.length - 1))];
}
const stats = (v) => ({ p50: pct(v, 50), p95: pct(v, 95), p99: pct(v, 99) });

// ---- raw HTTP ----
async function http(method, url, body, headers = {}, timeoutMs = 30_000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method, signal: ctrl.signal,
      headers: { "content-type": "application/json", ...headers },
      body: body === undefined ? undefined : (typeof body === "string" ? body : JSON.stringify(body)),
    });
    const raw = await res.text();
    let json = raw;
    try { json = JSON.parse(raw); } catch { /* keep raw */ }
    return { status: res.status, body: json };
  } catch (e) {
    // network-level failure (refused/aborted): degrade to status 0 so per-hop
    // error accounting sees it; the loop aborts if the substrate is gone.
    return { status: 0, body: { harness_transport_error: String(e?.cause?.code ?? e?.message ?? e).slice(0, 120) } };
  } finally { clearTimeout(t); }
}

let errorCount = 0;
const hopErr = {};
function noteErr(hop, e) {
  errorCount++;
  hopErr[hop] = (hopErr[hop] ?? 0) + 1;
  if (errorCount <= 10) log(`ERR hop=${hop} ${e?.name}: ${String(e?.message ?? e).slice(0, 160)}`);
}

// ===========================================================================
// substrate boot (mirrors c3 pattern)
// ===========================================================================
let sub = null, nextProc = null;
async function portUp(p) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1500 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("error", () => resolve(false));
    s.once("timeout", () => { s.destroy(); resolve(false); });
  });
}
async function bootSubstrate() {
  const ports = [39640, 39641, 39642, 39643, 39644, 39645, 39650];
  for (const p of ports) {
    if (await portUp(p)) throw new Error(`port ${p} occupied — refusing to boot`);
  }
  const sharedKey = crypto.randomBytes(48).toString("base64");
  const code = [
    `Application.put_env(:smalt, :arm_port, 39640)`,
    `Application.put_env(:smalt, :egress_port, 39641)`,
    `Application.put_env(:smalt, :amqp_port, 39642)`,
    `Application.put_env(:smalt, :event_hubs_port, 39643)`,
    `Application.put_env(:smalt, :arm_tls_port, 39644)`,
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:39642")`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
    `Process.sleep(:infinity)`,
  ].join("; ");
  const logDir = path.join(REPO, "tmp");
  fs.mkdirSync(logDir, { recursive: true });
  const logFile = fs.createWriteStream(path.join(logDir, "lc1-substrate.log"), { flags: "w" });
  sub = spawn("mix", ["run", "--no-start", "--no-halt", "-e", code], {
    cwd: REPO,
    env: { ...process.env, MIX_ENV: "test" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  sub.stdout.pipe(logFile); sub.stderr.pipe(logFile);
  const t0 = Date.now();
  for (;;) {
    const ups = await Promise.all([39640, 39641, 39642, 39643, 39644].map(portUp));
    if (ups.every(Boolean)) break;
    if (Date.now() - t0 > 150_000) throw new Error(`substrate not up in 150s; log tmp/lc1-substrate.log`);
    await sleep(700);
  }
  return sharedKey;
}
async function bootNext() {
  const logFile = fs.createWriteStream(path.join(REPO, "tmp", "lc1-next.log"), { flags: "w" });
  nextProc = spawn("node", ["node_modules/next/dist/bin/next", "start", "-p", "39650", "-H", "127.0.0.1"], {
    cwd: path.join(REPO, "workspace"),
    env: { ...process.env, SMALT_RATE_CAPACITY: "20000", SMALT_RATE_REFILL: "5000" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  nextProc.stdout.pipe(logFile); nextProc.stderr.pipe(logFile);
  const t0 = Date.now();
  for (;;) {
    if (await portUp(39650)) break;
    if (Date.now() - t0 > 90_000) throw new Error("next start did not open 39650 in 90s; log tmp/lc1-next.log");
    await sleep(500);
  }
}
function downAll() {
  for (const p of [sub, nextProc]) {
    if (!p) continue;
    try { process.kill(-p.pid, "SIGKILL"); } catch { try { p.kill("SIGKILL"); } catch {} }
  }
}
process.on("exit", downAll);
process.on("SIGINT", () => process.exit(130));

// ===========================================================================
// main
// ===========================================================================
fs.mkdirSync(path.dirname(JSONL), { recursive: true });
fs.writeFileSync(JSONL, ""); // fresh run overwrites

log("booting smalt substrate (ports 39640-39644)...");
const sharedKey = await bootSubstrate();
log("substrate up; booting next workspace (39650)...");
await bootNext();
log("next up");

// ---- hop 1 smoke + bearer (substrate accepts any bearer per MIX_ENV=test) ----
const tMint = performance.now();
const mint = await http("POST", `${ARM}/oauth2/v2.0/token`,
  new URLSearchParams({ grant_type: "client_credentials", client_id: "lc1", client_secret: "dev" }).toString(),
  { "content-type": "application/x-www-form-urlencoded" });
if (mint.status !== 200 || !mint.body?.access_token) {
  throw new Error(`STS mint failed ${mint.status}: ${JSON.stringify(mint.body).slice(0, 200)}`);
}
const BEARER = mint.body.access_token;
const mintMs = performance.now() - tMint;
log(`STS bearer minted (${mintMs.toFixed(1)} ms)`);
const AUTH = { authorization: `Bearer ${BEARER}` };

// ---- KV key (RSA) via substrate route ----
const KV_KEY = "lc1-tax-key";
let kv = await http("POST", `${VAULT}/keys/${KV_KEY}/create?api-version=7.4`, { kty: "RSA" }, AUTH);
if (kv.status !== 200) {
  // https self-signed: node fetch rejects unless env flag; try http once in case
  kv = await http("POST", `http://127.0.0.1:${VAULT_TLS}/keys/${KV_KEY}/create?api-version=7.4`, { kty: "RSA" }, AUTH);
  if (kv.status !== 200) throw new Error(`KV key create failed ${kv.status}: ${JSON.stringify(kv.body).slice(0, 200)}`);
}
log("KV RSA key created");

// ---- cosmos setup: db/container ----
const MASTER_KEY = crypto.randomBytes(32).toString("hex");
const cosmos = new CosmosClient({
  endpoint: EGRESS, key: MASTER_KEY,
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});
const DB = `lc1db-${Date.now()}`;
const { database } = await databaseCreate(cosmos, DB);
const { container } = await database.containers.createIfNotExists({ id: "taxcases", partitionKey: { paths: ["/pk"] } });
async function databaseCreate(c, id) { return c.databases.createIfNotExists({ id }); }
log(`cosmos db=${DB} container=taxcases`);

// ---- blob container (compliance journal) ----
const cred = new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY);
const blobs = new BlobServiceClient(`${EGRESS}/${ACCOUNT}`, cred);
const containerCli = blobs.getContainerClient(TX_CONTAINER);
await containerCli.createIfNotExists();
log(`blob container ${TX_CONTAINER} ready`);

// ---- EH producer ----
const conn =
  `Endpoint=sb://127.0.0.1:${EH_PORT};SharedAccessKeyName=RootManageSharedAccessKey;` +
  `SharedAccessKey=${sharedKey};EntityPath=${EHUB};UseDevelopmentEmulator=true`;
const producer = new EventHubProducerClient(conn, { retryOptions: { maxRetries: 0, timeoutInMs: 15_000 } });
const partitionIds = await producer.getPartitionIds({ abortSignal: AbortSignal.timeout(20_000) });
log(`EH producer connected; partitions=${partitionIds.length}`);

// ---- seed one storage account for the hop-7 Resource Graph analog ----
const SUB = "sub-lc1";
await http("PUT",
  `${ARM}/subscriptions/${SUB}/resourceGroups/lc1-rg/providers/Microsoft.Storage/storageAccounts/lc1seed?api-version=2021-04-01`,
  { location: "eastus", properties: { skuName: "Standard_LRS" } }, AUTH);
const rgSeed = await http("POST", `${EGRESS}/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`,
  { subscriptions: [SUB], query: "project id, name, type" }, AUTH);
log(`RG seed query: ${rgSeed.status} total=${rgSeed.body?.totalRecords ?? "?"}`);
const rgOk0 = rgSeed.status === 200;

// ---- sentinel workspace (DCR) ----
const DCR = `ws-lc1-${Date.now()}`;
log(`DCR=${DCR}`);

// ---- hop-2 sanity: HMAC probe once ----
const HMAC_KEY = "n4-dev-key";
function hmacSig(body) {
  return crypto.createHmac("sha256", HMAC_KEY).update(body).digest("hex");
}

// ===========================================================================
// lifecycle cycles
// ===========================================================================
const hopLat = { 1: [], 2: [], 3: [], 4: [], 5: [], 6: [], 7: [], 8: [] };
const e2eLat = [];
let cyclesOk = 0;
let sentinelRywVerified = 0;

const WARM = 5;
for (let c = 0; c < N_CYCLES + WARM; c++) {
  const isWarm = c < WARM;
  const txId = `lc1-tx-${c}-${Date.now()}`;
  const record = {
    txId, cycle: c, assessedAt: new Date().toISOString(),
    taxpayer: `tp-${c % 40}`, amount: Math.round(Math.random() * 100_000) / 100,
    jurisdiction: ["US-CA", "US-NY", "US-TX", "EU-DE"][c % 4],
  };
  const payload = JSON.stringify(record);
  const digest = crypto.createHash("sha256").update(payload).digest();
  const digestB64u = digest.toString("base64url");
  const tCycle = performance.now();

  // ---- hop 1: Entra (STS token) ----
  let t = performance.now();
  let r = await http("POST", `${ARM}/oauth2/v2.0/token`,
    new URLSearchParams({ grant_type: "client_credentials", client_id: "lc1", client_secret: "dev" }).toString(),
    { "content-type": "application/x-www-form-urlencoded" });
  let ms = performance.now() - t;
  if (r.status === 0) {
    log(`FATAL substrate transport failed at cycle ${c} (hop 1 status 0) — aborting run`);
    break;
  }
  if (r.status !== 200 || !r.body?.access_token) noteErr("1-sts", new Error(`status ${r.status}`));
  if (!isWarm) hopLat[1].push(ms);

  // ---- hop 2: APIM nearest-analog (Next /api/v1/ingest, token bucket) ----
  t = performance.now();
  r = await http("POST", `${NEXT}/api/v1/ingest`, payload, { "x-smalt-signature": hmacSig(payload) });
  ms = performance.now() - t;
  if (r.status !== 202) noteErr("2-apim", new Error(`status ${r.status}: ${JSON.stringify(r.body).slice(0, 120)}`));
  if (!isWarm) hopLat[2].push(ms);

  // ---- hop 3: Cosmos CAS etag replace ----
  t = performance.now();
  try {
    const pk = `part-${c % 10}`;
    const created = await container.items.create({ id: txId, pk, txId, stage: "submitted", record });
    const etag = created.resource._etag;
    const replaced = await container.item(txId, pk).replace(
      { id: txId, pk, txId, stage: "assessed", etagStamper: "lc1", record },
      { ifMatchEtag: etag });
    if (!replaced.resource?._etag) throw new Error("no etag on replace");
  } catch (e) { noteErr("3-cosmos", e); }
  ms = performance.now() - t;
  if (!isWarm) hopLat[3].push(ms);

  // ---- hop 4: KV sign (RS256 over digest) ----
  t = performance.now();
  r = await http("POST", `${VAULT}/keys/${KV_KEY}/sign?api-version=7.4`,
    { alg: "RS256", digest: digestB64u }, AUTH);
  ms = performance.now() - t;
  let sigOk = r.status === 200 && !!r.body?.value;
  if (!sigOk) noteErr("4-kvsign", new Error(`status ${r.status}: ${JSON.stringify(r.body).slice(0, 120)}`));
  if (!isWarm) hopLat[4].push(ms);

  // ---- hop 5: EH producer send (1 event, AMQP SDK) ----
  t = performance.now();
  try {
    const pid = partitionIds[c % partitionIds.length];
    const batch = await producer.createBatch({ partitionId: pid, abortSignal: AbortSignal.timeout(20_000) });
    if (!batch.tryAdd({ body: payload })) throw new Error("tryAdd failed");
    await producer.sendBatch(batch, { abortSignal: AbortSignal.timeout(20_000) });
  } catch (e) { noteErr("5-eh", e); }
  ms = performance.now() - t;
  if (!isWarm) hopLat[5].push(ms);

  // ---- hop 6: Blob journal (PUT — no append surface) ----
  const blobName = `journal/${new Date().toISOString().slice(0, 10)}/${txId}.json`;
  t = performance.now();
  try {
    await containerCli.getBlockBlobClient(blobName).upload(payload, payload.length,
      { abortSignal: AbortSignal.timeout(30_000) });
  } catch (e) { noteErr("6-blob", e); }
  ms = performance.now() - t;
  if (!isWarm) hopLat[6].push(ms);

  // ---- hop 7: Search ABSENT -> Resource Graph nearest-analog query ----
  t = performance.now();
  r = await http("POST", `${EGRESS}/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`,
    { subscriptions: [SUB], query: "project id, name, type" }, AUTH);
  ms = performance.now() - t;
  if (r.status !== 200) noteErr("7-rg", new Error(`status ${r.status}`));
  if (!isWarm) hopLat[7].push(ms);

  // ---- hop 8: Sentinel ingest + synchronous RYW KQL read-back ----
  t = performance.now();
  let rywOk = false;
  try {
    const row = { TimeGenerated: new Date().toISOString(), TxId: txId, stage: "filed", amount: record.amount, pad: "y".repeat(400) };
    const ing = await http("POST",
      `${EGRESS}/dataCollectionRules/${DCR}/streams/Custom-Logs?api-version=2023-01-01`, [row], AUTH);
    if (ing.status !== 204) throw new Error(`ingest status ${ing.status}`);
    const q = await http("POST", `${EGRESS}/v1/workspaces/${DCR}/query`,
      { query: `Custom-Logs | where TxId == '${txId}' | take 1` }, AUTH);
    if (q.status !== 200) throw new Error(`query status ${q.status}`);
    const rows = q.body?.tables?.[0]?.rows ?? [];
    rywOk = rows.length === 1 && rows[0].some((v) => v === txId);
  } catch (e) { noteErr("8-sentinel", e); }
  ms = performance.now() - t;
  if (rywOk && !isWarm) sentinelRywVerified++;
  if (!isWarm) hopLat[8].push(ms);

  const e2e = performance.now() - tCycle;
  if (!isWarm) e2eLat.push(e2e);
  if (c === N_CYCLES + WARM - 1) log("cycles complete");
}
cyclesOk = e2eLat.length;

// ===========================================================================
// emit
// ===========================================================================
const totalOps = N_CYCLES * 8;
const surfs = {
  1: ["sts", "REAL"], 2: ["next-ingest", "NEAREST_ANALOG"], 3: ["cosmos-cas", "REAL"],
  4: ["kv-sign", "REAL"], 5: ["eventhubs", "SDK"], 6: ["blob-journal", "PUT-journal"],
  7: ["resource-graph", "NEAREST_ANALOG"], 8: ["sentinel-ryw", "REAL"],
};
const durations = {};
for (const h of [1, 2, 3, 4, 5, 6, 7, 8]) {
  const [surf, mapping] = surfs[h];
  const s = stats(hopLat[h]);
  durations[h] = s;
  const hopErrors = Object.entries(hopErr)
    .filter(([k]) => k.startsWith(`${h}-`))
    .reduce((a, [, v]) => a + v, 0);
  emit(`cloud-chain-${surf}`, `hop${h}`, hopLat[h].length, 1000 / (s.p50 || 1), s.p50, s.p95, s.p99, hopErrors, { mapping });
}
const es = stats(e2eLat);
emit("cloud-chain-e2e", "cycle", e2eLat.length, 1000 / (es.p50 || 1), es.p50, es.p95, es.p99, errorCount, {
  cycles_requested: N_CYCLES, cycles_completed: cyclesOk, warmup: WARM,
  sentinel_ryw_verified: sentinelRywVerified,
  per_hop_p50_ms: Object.fromEntries(Object.entries(durations).map(([h, s]) => [h, s.p50])),
});

// ---- KD-absent list ----
const kdAbsent = [
  { kd: "KD-APIM-ABSENT", hop: 2, note: "no APIM gateway surface in smalt; nearest-analog = workspace Next /api/v1/ingest token-bucket handler" },
  { kd: "KD-APPEND-ABSENT", hop: 6, note: "no append-blob surface in smalt blob_storage/blob_service; PUT block blob to compliance container used as journal" },
  { kd: "KD-SEARCH-ABSENT", hop: 7, note: "no Cognitive Search surface in smalt; nearest-analog = Resource Graph query" },
];
fs.appendFileSync(JSONL, JSON.stringify({
  lane: LANE, op: "kd-absent", machine: MACHINE, kd_absent: kdAbsent,
  as_of: new Date().toISOString(),
}) + "\n");

// ---- cost ledger: 1M-cycle extrapolation (published rates, as-of-knowledge 2026-10) ----
const RATES = {
  entra_token: { usd: 0.0, unit: "free at published 2026-10 tiers" },
  apim_unit: { usd: 0.000_003_5, unit: "per call (Standard tier, published 2026-10)" },
  kv_sign: { usd: 0.000_003, unit: "per RSA-2048 sign transaction (published 2026-10)" },
  eh_ingress: { usd: 0.000_028, unit: "per event (Standard: $0.028 per million events, published 2026-10)" },
  blob_put: { usd: 0.000_005, unit: "per write (LRS hot: $0.05 per 10,000 writes, published 2026-10)" },
  search: { usd: 0.0, unit: "ABSENT in smalt — no Cognitive Search surface; not costed" },
  sentinel_analysis: { usd: 4.3, unit: "per GB ingested (Log Analytics analytic tier, published 2026-10)" },
};
const GB_ROW = 0.000_000_5; // ~500B
const costPerCycle =
  RATES.apim_unit.usd +
  RATES.kv_sign.usd +
  RATES.eh_ingress.usd +
  RATES.blob_put.usd +
  RATES.sentinel_analysis.usd * GB_ROW;
const cost1M = costPerCycle * 1_000_000;
fs.appendFileSync(JSONL, JSON.stringify({
  lane: LANE, op: "cost-ledger-1M", machine: MACHINE,
  cycles: 1_000_000, api_ops: 8_000_000,
  usd_per_cycle: +costPerCycle.toFixed(9), usd_per_1m_cycles: +cost1M.toFixed(2),
  rates_as_of: "published Microsoft list pricing as-of-knowledge 2026-10, not a quote",
  breakdown: {
    apim_hop2: RATES.apim_unit.usd, kv_sign_hop4: RATES.kv_sign.usd,
    eh_hop5: RATES.eh_ingress.usd, blob_hop6: RATES.blob_put.usd,
    sentinel_hop8: +(RATES.sentinel_analysis.usd * GB_ROW).toFixed(9),
    entra_hop1: 0, cosmos_hop3: "RU-based, excluded (throughput-mode dependent)",
    search_hop7: "ABSENT, not costed",
  },
}) + "\n");
log(`COST ledger: $${costPerCycle.toFixed(9)}/cycle -> $${cost1M.toFixed(2)} per 1M cycles (as-of-knowledge rates)`);

log(`DONE cycles=${cyclesOk} sentinel_ryw_verified=${sentinelRywVerified} errors=${errorCount}`);
await Promise.race([producer.close().catch(() => {}), sleep(5_000)]);
downAll();
process.exit(errorCount > N_CYCLES ? 1 : 0);
