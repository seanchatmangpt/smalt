// c8_chaos_cross.mjs — lane C-8: cross-product chaos overlay load driver.
//
// Three sustained workers against ONE live substrate (booted by the
// orchestrator c8_chaos_overlay.sh on the c8 port block 39080..39085):
//   blob   — put-block-blob 8 KiB, unique name per put (substrate enforces WORM
//            immutability), self-healing container re-creation after restart.
//   cosmos — point-reads of 200 seeded docs; on failure re-provisions (db +
//            container + reseed) best-effort, then keeps reading.
//   eh     — Event Hubs send 1 KiB over AMQP; producer recreated after any
//            send failure (a broken AMQP link is not reusable).
//
// The orchestrator SIGKILLs the substrate twice (t=60s uniform traffic, t=180s
// under cosmos-emphasized traffic) and re-boots it; the driver keeps running
// and records per-op events so PER-SURFACE recovery is measured, not assumed:
//   event = {ts, t, surface, ok, latency_ms, err?}   (ts = epoch ms)
//
// Emphasis phase: C8_EMPHASIS_FILE containing "cosmos" => cosmos worker runs
// 5x pacing, blob/eh slow to ~1/6 rate.
//
// No commits, no lib edits.
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(path.join(REPO, "test/sdk-full/package.json"));
const { BlobServiceClient, StorageSharedKeyCredential } = require("@azure/storage-blob");
const { CosmosClient } = await import(
  path.join(REPO, "test/sdk-full/node_modules/@azure/cosmos/dist/esm/index.js"));
const { EventHubProducerClient } = await import(
  path.join(REPO, "test/sdk-full/node_modules/@azure/event-hubs/dist/esm/index.js"));

const EGRESS = Number(process.env.C8_EGRESS_PORT || 39081);
const EHUB = Number(process.env.C8_EHUB_PORT || 39083);
const OUT = process.env.C8_OUT ||
  path.join(REPO, "docs/jira/v26.10.14/bench/c8-chaos-cross.jsonl");
const EMPHASIS_FILE = process.env.C8_EMPHASIS_FILE ||
  path.join(REPO, "tmp/c8-emphasis.txt");
const END = Number(process.env.C8_T0_EPOCH || 0) + Number(process.env.C8_DURATION_MS || 270000);

const ACCOUNT = "smaltacct";
const ACCOUNT_KEY = "smaltacct-key";
const TAG = Date.now();
const OP_TIMEOUT_MS = 20000;
const withTimeout = (p, ms) =>
  Promise.race([
    p,
    new Promise((_, rej) =>
      setTimeout(() => rej(new Error("C8_OP_TIMEOUT")), ms || OP_TIMEOUT_MS)),
  ]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(new Date().toISOString(), ...a);

// ---- event sink -------------------------------------------------------------
fs.mkdirSync(path.dirname(OUT), { recursive: true });
const sink = fs.createWriteStream(OUT, { flags: "a" });
function emit(surface, ok, latencyMs, err) {
  const rec = { ts: Date.now(), surface, ok, latency_ms: latencyMs };
  if (!ok) rec.err = String((err && err.message) || err).slice(0, 120);
  sink.write(JSON.stringify(rec) + "\n");
}

// ---- clients -----------------------------------------------------------------
const SB_SHARED_KEY = process.env.C8_SB_KEY || randomBytes(48).toString("base64");
const service = new BlobServiceClient(
  "http://127.0.0.1:" + EGRESS + "/" + ACCOUNT,
  new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY),
);
const cosmos = new CosmosClient({
  endpoint: "http://127.0.0.1:" + EGRESS,
  key: randomBytes(32).toString("hex"),
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});
const EH_CS =
  "Endpoint=sb://127.0.0.1:" + EHUB +
  ";SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=" + SB_SHARED_KEY +
  ";EntityPath=c8-hub;UseDevelopmentEmulator=true";
const CLI_OPTS = {
  retryOptions: { maxRetries: 0, retryDelayInMs: 500, timeoutInMs: 10000 },
};

const payload = randomBytes(8192);
const ehBody = randomBytes(1024);

function emphasis() {
  try { return fs.readFileSync(EMPHASIS_FILE, "utf8").trim(); }
  catch (e) { return ""; }
}

// ---- workers -----------------------------------------------------------------
async function blobWorker(until) {
  const container = service.getContainerClient("c8-" + TAG);
  await withTimeout(container.createIfNotExists());
  let i = 0;
  while (Date.now() < until) {
    const s = Date.now();
    const put = container.getBlockBlobClient("b-" + TAG + "-" + i);
    try {
      await withTimeout(put.upload(payload, payload.length));
      emit("blob", true, Date.now() - s);
    } catch (e) {
      emit("blob", false, Date.now() - s, e);
      await withTimeout(container.createIfNotExists()).catch(() => {});
    }
    i++;
    await sleep(emphasis() === "cosmos" ? 120 : 20);
  }
}

async function cosmosWorker(until) {
  const N = 200;
  let cc = null;
  const provision = async () => {
    const { database } = await withTimeout(
      cosmos.databases.createIfNotExists({ id: "c8db-" + TAG }));
    const res = await withTimeout(database.containers.createIfNotExists({
      id: "c1", partitionKey: { paths: ["/pk"] },
    }));
    cc = res.container;
    for (let i = 0; i < N; i++) {
      await withTimeout(cc.items.upsert({
        id: "d" + i, pk: "p" + (i % 8), v: i, pad: "x".repeat(64),
      }));
    }
  };
  await provision();
  log("cosmos seeded " + N + " docs");
  let i = 0;
  while (Date.now() < until) {
    const emp = emphasis() === "cosmos";
    const reps = emp ? 5 : 1;
    for (let r = 0; r < reps && Date.now() < until; r++) {
      const s = Date.now();
      try {
        const out = await withTimeout(
          cc.item("d" + (i % N), "p" + ((i % N) % 8)).read());
        if (!out.resource) throw new Error("C8_COSMOS_EMPTY_READ");
        emit("cosmos", true, Date.now() - s);
      } catch (e) {
        emit("cosmos", false, Date.now() - s, e);
        await provision().catch(() => {});
      }
      i++;
    }
    await sleep(emp ? 10 : 50);
  }
}

async function ehWorker(until) {
  let producer = null;
  while (Date.now() < until) {
    if (!producer) {
      producer = new EventHubProducerClient(EH_CS, "c8-hub", CLI_OPTS);
    }
    const s = Date.now();
    try {
      const batch = await withTimeout(producer.createBatch());
      batch.tryAdd({ body: ehBody });
      await withTimeout(producer.sendBatch(batch));
      emit("eh", true, Date.now() - s);
    } catch (e) {
      emit("eh", false, Date.now() - s, e);
      try { await producer.close(); } catch (e2) { /* dead */ }
      producer = null;
    }
    await sleep(emphasis() === "cosmos" ? 300 : 50);
  }
  if (producer) { try { await producer.close(); } catch (e) { /* dead */ } }
}

// ---- main --------------------------------------------------------------------
async function main() {
  log("c8 driver start, out=" + OUT);
  await Promise.all([blobWorker(END), cosmosWorker(END), ehWorker(END)]);
  sink.end();
  log("c8 driver done");
}
main().catch((e) => { log("c8 driver FATAL", e); process.exit(1); });
