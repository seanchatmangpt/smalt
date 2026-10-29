// SCVD-T12 lane: cross-surface ramp — 128 concurrent blob PUT/GET AND 128
// concurrent Service Bus send/receive against the LIVE substrate, riding the
// 9444 TLS twin (NODE_EXTRA_CA_CERTS + STS bearer, KD-15 handshake shape).
// Cosmos is covered by T1-T3; these two faces complete the coverage matrix.
// Emits tmp/bench/scvd-blob.jsonl + tmp/bench/scvd-sb.jsonl.
// Typed FAIL (exit 1) on any error at 128. Loud SKIP (exit 3) if substrate down.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const TS_DIR = path.join(REPO, "verification/ts");
const TLS = process.env.SCVD_TLS ?? "https://127.0.0.1:9444";
const ARM = process.env.SCVD_ARM ?? "http://127.0.0.1:9443";
const SB_HOST = "127.0.0.1:5672";
const OUT_BLOB = process.env.SCVD_OUT_BLOB ?? path.join(REPO, "tmp/bench/scvd-blob.jsonl");
const OUT_SB = process.env.SCVD_OUT_SB ?? path.join(REPO, "tmp/bench/scvd-sb.jsonl");
const CONCURRENCY = Number(process.env.SCVD_CONCURRENCY ?? 128);
const CYCLES_PER_WORKER = Number(process.env.SCVD_CYCLES ?? 4);
const WALL_BUDGET_MS = 60_000;

const log = (...a) => console.log(new Date().toISOString(), ...a);

const machine = {
  cpu: os.cpus()[0].model,
  cores: os.cpus().length,
  node: process.version,
  endpoint: TLS,
};

// ---- liveness probe (loud SKIP, never restart) -----------------------------
async function probe(url, expect401 = false) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(5000), redirect: "manual" });
    r.body?.cancel().catch(() => {});
    return expect401 ? r.status === 401 || r.status < 500 : r.status < 500;
  } catch {
    return false;
  }
}
const substrateUp = async () =>
  (await probe(`${ARM}/providers?api-version=2099-01-01`)) &&
  (await probe(`${TLS}/popcorn?restype=container`, true));

// ---- bearer via emulator STS (KD-15 handshake shape) -----------------------
async function mintToken() {
  const r = await fetch(`${TLS}/organizations/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=scvd-t12&client_secret=scvd-t12",
    signal: AbortSignal.timeout(10_000),
  });
  if (!r.ok) throw new Error(`STS mint failed: ${r.status}`);
  const j = await r.json();
  if (!j.access_token) throw new Error("STS mint: no access_token");
  return j.access_token;
}

// ---- shared emit ------------------------------------------------------------
function emitRow(file, lane, surface, op, n, opsPerSec, p50, p95, p99, errors, extra) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.appendFileSync(
    file,
    JSON.stringify({
      lane, surface, op, n, ops_per_sec: opsPerSec, p50_ms: p50, p95_ms: p95,
      p99_ms: p99, errors, wall_ms: extra.wallMs,
      concurrency: CONCURRENCY, cycles_per_worker: CYCLES_PER_WORKER,
      machine, standing: extra.standing,
      ...(extra.lastErr ? { last_err: extra.lastErr } : {}),
    }) + "\n",
  );
}

function pct(sorted, p) {
  const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return Number(sorted[Math.max(0, i)].toFixed(3));
}

// ===========================================================================
// Phase A — blob PUT/GET, 128 concurrent workers over the TLS twin
// ===========================================================================
async function blobLeg() {
  const azblob = createRequire(path.join(TS_DIR, "package.json"))("@azure/storage-blob");
  const token = await mintToken();
  const cred = {
    getToken: async () => ({ token, expiresOnTimestamp: Date.now() + 3600_000 }),
  };
  const service = new azblob.BlobServiceClient(`${TLS}/popcorn`, cred);
  const container = service.getContainerClient(`scvd-t12-${Date.now()}`);
  await container.create();

  const lat = [];
  let errors = 0, ops = 0;
  let lastErr = "";

  const worker = async (w) => {
    for (let c = 0; c < CYCLES_PER_WORKER; c++) {
      const name = `t12-${w}-${c}`;
      const payload = crypto.randomBytes(1024);
      let s = performance.now();
      try {
        const blk = container.getBlockBlobClient(name);
        await blk.upload(payload, payload.length);
        const dl = await blk.download();
        const chunks = [];
        for await (const ch of dl.readableStreamBody) chunks.push(Buffer.from(ch));
        const got = Buffer.concat(chunks);
        lat.push(performance.now() - s);
        ops++;
        if (!got.equals(payload)) {
          errors++; lastErr = `GET byte-mismatch ${name}`;
        }
      } catch (e) {
        lat.push(performance.now() - s);
        errors++; lastErr = `blob ${name}: ${String(e?.message ?? e).slice(0, 160)}`;
      }
    }
  };

  const t0 = Date.now();
  await Promise.all(Array.from({ length: CONCURRENCY }, (_, w) => worker(w)));
  const wallMs = Date.now() - t0;
  const sorted = [...lat].sort((a, b) => a - b);
  const standing = errors === 0 && wallMs <= WALL_BUDGET_MS ? "PASS" : "FAIL";
  const row = {
    lane: "scvd-t12", surface: "blob", op: `putget-c${CONCURRENCY}`, n: ops,
    ops_per_sec: Number((ops / (wallMs / 1000)).toFixed(1)),
    p50_ms: pct(sorted, 50), p95_ms: pct(sorted, 95), p99_ms: pct(sorted, 99),
    errors, wall_ms: wallMs, wall_budget_ms: WALL_BUDGET_MS,
    concurrency: CONCURRENCY, cycles_per_worker: CYCLES_PER_WORKER,
    machine, standing,
    ...(lastErr ? { last_err: lastErr.slice(0, 200) } : {}),
  };
  fs.mkdirSync(path.dirname(OUT_BLOB), { recursive: true });
  fs.appendFileSync(OUT_BLOB, JSON.stringify(row) + "\n");
  log(`BLOB n=${ops} ops/s=${row.ops_per_sec} p50=${row.p50_ms}ms p95=${row.p95_ms}ms p99=${row.p99_ms}ms errors=${errors} wall=${wallMs}ms standing=${standing}${lastErr ? " lastErr=" + lastErr : ""}`);
  return { standing, errors, wallMs, cleanup: () => container.delete().catch(() => {}) };
}

// ===========================================================================
// Phase B — Service Bus send/receive, 128 concurrent workers (per-worker
// queues so competing consumers cannot steal a peer's messages).
// ===========================================================================
async function sbLeg() {
  const { ServiceBusClient, ServiceBusAdministrationClient } = createRequire(
    path.join(TS_DIR, "package.json"),
  )("@azure/service-bus");

  // Live-substrate SAS key (substrate.sh contract): per-host dev key or the
  // historical pinned default. Queue provisioning via the SDK admin client
  // (createQueue over the AMQP endpoint's HTTP management face — witnessed
  // working; deleteQueue trips a server-side HTTP framing bug, so queues are
  // minted with autoDeleteOnIdle=PT2M for self-cleanup instead).
  const perHost = Buffer.from(
    crypto.createHash("sha256").update(`${os.hostname()}smalt-dev-sb`).digest(),
  ).toString("base64");
  const cs = (key) =>
    `Endpoint=sb://${SB_HOST};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${key};UseDevelopmentEmulator=true`;

  let admin, client, usedKey = "";
  for (const key of [perHost, "ws8sharedkey"]) {
    try {
      admin = new ServiceBusAdministrationClient(cs(key));
      await admin.createQueue({ name: `scvd-t12-probe-${Date.now()}`, autoDeleteOnIdle: "PT2M" });
      client = new ServiceBusClient(cs(key), { retryOptions: { maxRetries: 0, timeoutInMs: 15_000 } });
      usedKey = key === perHost ? "per-host" : "ws8sharedkey";
      break;
    } catch (e) {
      admin = undefined; client = undefined;
      log(`SB key ${key.slice(0, 8)} rejected: ${String(e?.message ?? e).slice(0, 120)}`);
    }
  }
  if (!client) {
    log("SKIP: live substrate SB plane not admitting either known dev key — never restart");
    return { standing: "SKIP", errors: 0, wallMs: 0, cleanup: () => {} };
  }
  log(`SB key admitted: ${usedKey}`);

  const queueNames = [];
  const t0p = Date.now();
  for (let w = 0; w < CONCURRENCY; w++) {
    const q = `scvd-t12-q${w}`;
    await admin.createQueue({ name: q, autoDeleteOnIdle: "PT2M", maxDeliveryCount: 3 });
    queueNames.push(q);
  }
  log(`provisioned ${queueNames.length} queues in ${Date.now() - t0p}ms`);

  const lat = [];
  let errors = 0, ops = 0;
  let lastErr = "";

  const worker = async (w) => {
    const q = queueNames[w];
    const sender = client.createSender(q);
    const receiver = client.createReceiver(q, { receiveMode: "receiveAndDelete" });
    try {
      for (let c = 0; c < CYCLES_PER_WORKER; c++) {
        const body = crypto.randomBytes(1024).toString("hex");
        const messageId = `t12-${w}-${c}`;
        let s = performance.now();
        try {
          await sender.sendMessages({ body, messageId });
          const msgs = await receiver.receiveMessages(1, { maxWaitTimeInMs: 15_000 });
          if (msgs.length === 1 && msgs[0].body === body && msgs[0].messageId === messageId) {
            ops += 2; lat.push(performance.now() - s);
          } else {
            errors++; lastErr = `recv mismatch/empty q=${q} got=${msgs.length}`;
            lat.push(performance.now() - s);
          }
        } catch (e) {
          lat.push(performance.now() - s);
          errors++; lastErr = `sb ${q}: ${String(e?.message ?? e).slice(0, 160)}`;
        }
      }
    } finally {
      await sender.close().catch(() => {});
      await receiver.close().catch(() => {});
    }
  };

  const t0 = Date.now();
  await Promise.all(Array.from({ length: CONCURRENCY }, (_, w) => worker(w)));
  const wallMs = Date.now() - t0;
  const sorted = [...lat].sort((a, b) => a - b);
  const standing = errors === 0 && wallMs <= WALL_BUDGET_MS ? "PASS" : "FAIL";
  const row = {
    lane: "scvd-t12", surface: "servicebus", op: `sendrecv-c${CONCURRENCY}`, n: ops,
    ops_per_sec: Number((ops / (wallMs / 1000)).toFixed(1)),
    p50_ms: pct(sorted, 50), p95_ms: pct(sorted, 95), p99_ms: pct(sorted, 99),
    errors, wall_ms: wallMs, wall_budget_ms: WALL_BUDGET_MS,
    concurrency: CONCURRENCY, cycles_per_worker: CYCLES_PER_WORKER,
    machine, standing,
    ...(lastErr ? { last_err: lastErr.slice(0, 200) } : {}),
  };
  fs.mkdirSync(path.dirname(OUT_SB), { recursive: true });
  fs.appendFileSync(OUT_SB, JSON.stringify(row) + "\n");
  log(`SB n=${ops} ops/s=${row.ops_per_sec} p50=${row.p50_ms}ms p95=${row.p95_ms}ms p99=${row.p99_ms}ms errors=${errors} wall=${wallMs}ms standing=${standing}${lastErr ? " lastErr=" + lastErr : ""}`);

  return {
    standing, errors, wallMs,
    cleanup: async () => {
      // deleteQueue trips the server-side HTTP framing bug — self-cleanup via
      // autoDeleteOnIdle instead; best-effort delete anyway.
      for (const q of queueNames) await admin.deleteQueue(q).catch(() => {});
    },
  };
}

// ===========================================================================
// main — substrate down = loud SKIP (exit 3), never restart.
// ===========================================================================
if (!(await substrateUp())) {
  log("SKIP: live substrate down (9443/9444/5672 not serving) — lane law: never restart");
  const skipRow = (surface) => ({
    lane: "scvd-t12", surface, op: "skip-substrate-down", n: 0, ops_per_sec: 0,
    p50_ms: 0, p95_ms: 0, p99_ms: 0, errors: 0, wall_ms: 0,
    machine, standing: "SKIP",
  });
  fs.mkdirSync(path.dirname(OUT_BLOB), { recursive: true });
  fs.appendFileSync(OUT_BLOB, JSON.stringify(skipRow("blob")) + "\n");
  fs.appendFileSync(OUT_SB, JSON.stringify(skipRow("servicebus")) + "\n");
  process.exit(3);
}

const blob = await blobLeg();
const sb = await sbLeg();
await blob.cleanup();

const verdicts = [blob.standing, sb.standing];
if (verdicts.includes("SKIP")) {
  console.log("SCVD-T12 SKIP");
  process.exit(3);
}
process.exit(verdicts.every((v) => v === "PASS") ? 0 : 1);
