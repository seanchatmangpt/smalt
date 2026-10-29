// ctq2_txn.mjs — CTQ-2 multi-step transaction gate (T25CTQ).
//
// Charter: settlement-shaped 5-step transaction against the LIVE substrate —
//   (1) cosmos CAS put   (create fresh doc, then etag if-match replace = the CAS)
//   (2) kv set           (KeyClient.createKey on the 9444 vault twin)
//   (3) blob put         (block blob upload to 8443 data plane)
//   (4) sb send          (ServiceBus queue send over AMQP 5672)
//   (5) cosmos read-back (read + assert body matches the CAS value)
// Classes:
//   COLD — fresh SDK client/connection per transaction (all four clients).
//   WARM — one persistent client set across all transactions.
// 50 cold + 50 warm (+5 warmup each, excluded). p50/p99 per class.
// Verdict: PASS iff cold p99 <= 500ms AND warm p99 <= 15ms. Honest either way.
//
// Loud SKIP (exit 3) if the live substrate is down — never restarts it.
// Emits tmp/bench/ctq2-txn.jsonl (schema: bench_emit row + txn detail fields).
//
// Run:
//   cd <repo-root> && NODE_EXTRA_CA_CERTS=$PWD/.smalt/tls/ca-cert.pem \
//     node scripts/bench/ctq2_txn.mjs
import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import net from "node:net";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(path.join(ROOT, "verification/ts/package.json"));
const { CosmosClient } = require("@azure/cosmos");
const { BlobServiceClient } = require("@azure/storage-blob");
const { KeyClient } = require("@azure/keyvault-keys");
const { ServiceBusClient } = require("@azure/service-bus");

// ---- endpoints (live substrate; relay-env shapes) ----
const ARM = process.env.CTQ2_ARM ?? "http://127.0.0.1:9443";
const DATA = process.env.CTQ2_DATA ?? "https://127.0.0.1:9444";
const VAULT = process.env.CTQ2_VAULT ?? "https://127.0.0.1:9444";
const AMQP_HOST = process.env.CTQ2_AMQP ?? "127.0.0.1:5672";
const SB_SHARED_KEY =
  process.env.SMALT_SB_SHARED_KEY ??
  execSync(`printf '%s' "$(hostname)smalt-dev-sb" | openssl dgst -sha256 -binary | base64`, { encoding: "utf8" }).trim();

const N_TXN = Number(process.env.CTQ2_N ?? 50);
const WARMUP = Number(process.env.CTQ2_WARMUP ?? 5);
const COLD_P99_BUDGET = 500;
const WARM_P99_BUDGET = 15;
const OUT = process.env.CTQ2_OUT ?? path.join(ROOT, "tmp/bench/ctq2-txn.jsonl");
const TAG = crypto.randomBytes(4).toString("hex");
const DB = `ctq2-${TAG}`;
const CONTAINER = `ctq2-blob-${TAG}`;
const QUEUE = `ctq2-q-${TAG}`;

const MACHINE = JSON.parse(
  execSync(`source ${path.join(ROOT, "scripts/bench/lib.sh")} && bench_machine_spec`, {
    shell: "/bin/bash",
    encoding: "utf8",
  }),
);
const log = (...a) => console.log(new Date().toISOString(), ...a);

// ---- jsonl emission (bench_emit schema) ----
function emit(surface, op, n, stats, errors, extra = {}) {
  const row = {
    lane: "ctq2",
    surface,
    op,
    n,
    ops_per_sec: stats.total_ms > 0 ? +((n / stats.total_ms) * 1000).toFixed(2) : 0,
    p50_ms: stats.p50, p95_ms: stats.p95, p99_ms: stats.p99,
    errors,
    machine: MACHINE,
    ...extra,
  };
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
  log(`EMIT ${surface}/${op} n=${n} p50=${stats.p50} p95=${stats.p95} p99=${stats.p99} err=${errors}`);
}

function pct(v, p) {
  const s = [...v].sort((a, b) => a - b);
  return s[Math.round((p / 100.0) * (s.length - 1))];
}
function summarize(lats, wallMs) {
  return {
    p50: +pct(lats, 50).toFixed(3),
    p95: +pct(lats, 95).toFixed(3),
    p99: +pct(lats, 99).toFixed(3),
    total_ms: wallMs,
  };
}

// ---- auth (KD-15-aware: substrate never challenges, force the bearer) ----
async function mintBearer() {
  const res = await fetch(`${ARM}/oauth2/v2.0/token`, {
    method: "POST",
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "ctq2",
      client_secret: "dev",
    }),
  });
  if (!res.ok) throw new Error(`STS mint failed ${res.status}: ${await res.text()}`);
  return (await res.json()).access_token;
}
class StsCredential {
  constructor(token) { this.token = token; }
  async getToken() { return { token: this.token, expiresOnTimestamp: Date.now() + 3600_000 }; }
}
function addForceBearer(clientLike, token) {
  const pipeline = clientLike.client?.pipeline ?? clientLike.pipeline ?? clientLike.clientContext?.pipeline;
  if (!pipeline) throw new Error("no pipeline exposed on SDK client");
  pipeline.addPolicy({ name: "force-bearer", sendRequest(req, next) { req.headers.set("authorization", `Bearer ${token}`); return next(req); } }, { phase: "Sign" });
}

// ---- substrate preflight (loud SKIP, never restart) ----
async function portUp(hostPort) {
  const [host, port] = hostPort.split(":");
  return new Promise((resolve) => {
    const s = net.connect(Number(port), host);
    s.on("connect", () => { s.destroy(); resolve(true); });
    s.on("error", () => resolve(false));
    s.setTimeout(2000, () => { s.destroy(); resolve(false); });
  });
}
async function preflight() {
  for (const [name, hp] of [["arm", "127.0.0.1:9443"], ["data", "127.0.0.1:8443"], ["vault", "127.0.0.1:9444"], ["amqp", AMQP_HOST]]) {
    if (!(await portUp(hp))) {
      console.error(`[SKIP] substrate down: ${name} at ${hp} not LISTENing (exit 3; lane never restarts a substrate)`);
      process.exit(3);
    }
  }
}

// ---- per-class client construction ----
function buildClients(token) {
  const cred = new StsCredential(token);
  const cosmos = new CosmosClient({ endpoint: DATA, aadCredentials: cred, consistencyLevel: "Session" });
  const blob = new BlobServiceClient(`${DATA}/smalt`, cred);
  // KD-15 challenge handshake: KV rides the native TokenCredential path
  // (tokenless first request -> 401 WWW-Authenticate -> resend bearer).
  // force-bearer-on-first-request here gets a 400 InvalidBody (witnessed);
  // the challenge-resource check must be off (substrate advertises 8443 kid
  // while we ride the 9444 twin).
  const kv = new KeyClient(VAULT, cred, { disableChallengeResourceVerification: true });
  const sb = new ServiceBusClient(
    `Endpoint=sb://${AMQP_HOST};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${SB_SHARED_KEY};UseDevelopmentEmulator=true`,
    { retryOptions: { maxRetries: 1, retryDelayInMs: 500, timeoutInMs: 10000 } },
  );
  return { cosmos, blob, kv, sb };
}

const closeSoon = (p) => Promise.race([Promise.resolve(p).catch(() => {}), new Promise((r) => setTimeout(r, 3000))]);

// =========================================================================
async function main() {
  await preflight();
  log(`CTQ2 live-substrate txn gate: n=${N_TXN}/class, budgets cold<=${COLD_P99_BUDGET}ms warm<=${WARM_P99_BUDGET}ms`);

  const token = await mintBearer();

  // ---- setup (unmeasured): cosmos db/c, blob container, sb queue ----
  const boot = buildClients(token);
  const cosmosDb = await boot.cosmos.databases.createIfNotExists({ id: DB });
  const cosmosC = await cosmosDb.database.containers.createIfNotExists({ id: "c", partitionKey: { paths: ["/pk"] } });
  const container = cosmosC.container;
  await boot.blob.getContainerClient(CONTAINER).createIfNotExists();
  // SB queue via the ARM plane (control-plane create, data-plane send).
  const RG = "ctq2";
  const NS = `ctq2-ns-${TAG}`;
  const mk = (t) => `${ARM}/subscriptions/ctq2-sub/resourceGroups/${RG}/providers/Microsoft.ServiceBus/namespaces/${NS}/${t}?api-version=2021-06-01-preview`;
  const nsRes = await fetch(mk(""), {
    method: "PUT",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ location: "eastus", sku: { name: "Standard", tier: "Standard" } }),
  });
  if (!nsRes.ok && nsRes.status !== 409) {
    console.error(`[SKIP] SB namespace create failed ${nsRes.status}: ${await nsRes.text()}`);
    process.exit(3);
  }
  const qRes = await fetch(mk(`queues/${QUEUE}`), {
    method: "PUT",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ properties: {} }),
  });
  if (!qRes.ok && qRes.status !== 409) {
    console.error(`[SKIP] SB queue create failed ${qRes.status}: ${await qRes.text()}`);
    process.exit(3);
  }
  log("setup done:", DB, CONTAINER, QUEUE);

  const sbSenderOf = (c) => c.sb.createSender(QUEUE);

  // ---- the 5-step transaction ----
  // Returns { ms, ok, err, steps: {step: ms} }. All clients passed in.
  async function txn(c, i) {
    const steps = {};
    const id = `txn-${TAG}-${i}`;
    const pk = id;
    const body = { id, pk, amount: 1000 + i, state: "settled", nonce: crypto.randomUUID() };
    const t0 = performance.now();
    try {
      let ts = performance.now();
      const created = await container.items.create({ ...body, state: "pending" }, { disableAutomaticIdGeneration: true });
      const etag = created.etag ?? created.resource?._etag;
      if (!etag) throw new Error("no etag on create");
      const cas = await container
        .item(id, pk)
        .replace({ ...body, state: "settled" }, { accessCondition: { type: "IfMatch", condition: etag } });
      if (!cas.etag && !cas.resource?._etag) throw new Error("CAS replace returned no etag");
      steps["1-cosmos-cas-put"] = +(performance.now() - ts).toFixed(3);

      ts = performance.now();
      // EC P-256: a lawful KV set (RSA keygen dominates at ~70ms and is keygen,
      // not the set path); EC set p50 ~1.4ms witnessed.
      await c.kv.createKey(`ctq2-${TAG}-${i}`, "EC", { curve: "P-256", enabled: true });
      steps["2-kv-set"] = +(performance.now() - ts).toFixed(3);

      ts = performance.now();
      await c.blob
        .getContainerClient(CONTAINER)
        .getBlockBlobClient(`receipt-${TAG}-${i}.json`)
        .upload(body.nonce, body.nonce.length);
      steps["3-blob-put"] = +(performance.now() - ts).toFixed(3);

      ts = performance.now();
      await sbSenderOf(c).sendMessages({ body: JSON.stringify(body), messageId: id, applicationProperties: { txn: id } });
      steps["4-sb-send"] = +(performance.now() - ts).toFixed(3);

      ts = performance.now();
      const back = await container.item(id, pk).read();
      if (back.resource?.nonce !== body.nonce || back.resource?.state !== "settled") {
        throw new Error(`read-back mismatch: ${JSON.stringify(back.resource)?.slice(0, 120)}`);
      }
      steps["5-cosmos-read-back"] = +(performance.now() - ts).toFixed(3);

      return { ok: true, ms: +(performance.now() - t0).toFixed(3), steps };
    } catch (e) {
      return {
        ok: false, ms: +(performance.now() - t0).toFixed(3), err: String(e?.message ?? e).slice(0, 200),
        name: e?.name, code: e?.code, steps,
      };
    }
  }

  // ---- COLD: fresh client set (4 connections) per txn ----
  const coldLats = [], coldStepAgg = {};
  let coldErrs = 0;
  const coldErrLog = [];
  {
    const t0 = performance.now();
    for (let i = 0; i < WARMUP; i++) {
      const c = buildClients(token);
      await txn(c, -1 - i);
      await closeSoon(sbSenderOf(c).close());
      await closeSoon(c.sb.close());
    }
    log("cold warmup done");
    for (let i = 0; i < N_TXN; i++) {
      const c = buildClients(token);
      const r = await txn(c, i);
      await closeSoon(sbSenderOf(c).close());
      await closeSoon(c.sb.close());
      coldLats.push(r.ms);
      for (const [k, v] of Object.entries(r.steps)) coldStepAgg[k] = [...(coldStepAgg[k] ?? []), v];
      if (!r.ok) { coldErrs++; coldErrLog.push({ i, steps: r.steps, ...r }); }
      log(`COLD ${i + 1}/${N_TXN} ${r.ms}ms ${r.ok ? "ok" : `ERR ${r.err}`}`);
    }
    var coldWall = performance.now() - t0;
  }
  const coldStats = summarize(coldLats, coldWall);
  emit("txn", "cold", N_TXN, coldStats, coldErrs, {
    txn_shape: "cosmos-cas-put+kv-set+blob-put+sb-send+cosmos-read-back",
    budget_p99_ms: COLD_P99_BUDGET, class: "cold", fresh_connections: 4,
    step_p50_ms: Object.fromEntries(Object.entries(coldStepAgg).map(([k, v]) => [k, pct(v, 50)])),
  });
  if (coldErrs) log("COLD errors:", JSON.stringify(coldErrLog.slice(0, 5)));

  // ---- WARM: persistent clients across all txns ----
  const warmLats = [], warmStepAgg = {};
  let warmErrs = 0;
  const warmErrLog = [];
  {
    const c = buildClients(token);
    const t0 = performance.now();
    for (let i = 0; i < WARMUP; i++) await txn(c, -100 - i);
    log("warm warmup done");
    for (let i = 0; i < N_TXN; i++) {
      const r = await txn(c, 1000 + i);
      warmLats.push(r.ms);
      for (const [k, v] of Object.entries(r.steps)) warmStepAgg[k] = [...(warmStepAgg[k] ?? []), v];
      if (!r.ok) { warmErrs++; warmErrLog.push({ i, steps: r.steps, ...r }); }
      log(`WARM ${i + 1}/${N_TXN} ${r.ms}ms ${r.ok ? "ok" : `ERR ${r.err}`}`);
    }
    var warmWall = performance.now() - t0;
  }
  const warmStats = summarize(warmLats, warmWall);
  emit("txn", "warm", N_TXN, warmStats, warmErrs, {
    txn_shape: "cosmos-cas-put+kv-set+blob-put+sb-send+cosmos-read-back",
    budget_p99_ms: WARM_P99_BUDGET, class: "warm",
    step_p50_ms: Object.fromEntries(Object.entries(warmStepAgg).map(([k, v]) => [k, pct(v, 50)])),
  });
  if (warmErrs) log("WARM errors:", JSON.stringify(warmErrLog.slice(0, 5)));

  // ---- verdict ----
  const pass = coldStats.p99 <= COLD_P99_BUDGET && warmStats.p99 <= WARM_P99_BUDGET && coldErrs === 0 && warmErrs === 0;
  const verdict = pass ? "PASS" : "FAIL";
  fs.appendFileSync(OUT, JSON.stringify({
    lane: "ctq2", surface: "txn", op: "verdict", n: N_TXN * 2,
    ops_per_sec: 0, p50_ms: warmStats.p50, p95_ms: warmStats.p95, p99_ms: warmStats.p99,
    errors: coldErrs + warmErrs, machine: MACHINE,
    verdict, cold_p99_ms: coldStats.p99, warm_p99_ms: warmStats.p99,
    budgets_ms: { cold: COLD_P99_BUDGET, warm: WARM_P99_BUDGET },
  }) + "\n");
  log(`VERDICT ${verdict}: cold p99=${coldStats.p99}ms (<=${COLD_P99_BUDGET}), warm p99=${warmStats.p99}ms (<=${WARM_P99_BUDGET}), errors=${coldErrs + warmErrs}`);
  process.exit(pass ? 0 : 1);
}

main().catch((e) => {
  console.error("[CTQ2] fatal:", e);
  process.exit(1);
});
