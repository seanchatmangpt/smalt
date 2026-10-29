// SCVD-T18 lane: Event Hubs ramp — 128 concurrent senders via @azure/event-hubs
// over the live AMQP wire (5673, plain sb://), per-host dev SAS key
// (base64(sha256(host + "smalt-dev-sb")), fallback pinned ws8sharedkey).
// 128 workers x 4 sends = 512 sends; each worker rides its own producer client
// (fresh connection/session/sender link). Send = AMQP settlement on the
// transfer, so a resolved send IS the ack. Typed FAIL (exit 1) on any error at
// 128. Loud SKIP (exit 3) if substrate down — never restart.
// Emits tmp/bench/scvd-eh.jsonl.
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const TS_DIR = path.join(REPO, "verification/ts");
const EH_PORT = Number(process.env.SCVD_EH_PORT ?? 5673);
const ARM = process.env.SCVD_ARM ?? "http://127.0.0.1:9443";
const OUT = process.env.SCVD_OUT ?? path.join(REPO, "tmp/bench/scvd-eh.jsonl");
const CONCURRENCY = Number(process.env.SCVD_CONCURRENCY ?? 128);
const SENDS_PER_WORKER = Number(process.env.SCVD_SENDS ?? 4);
const HUB = process.env.SCVD_EH_HUB ?? "scvd-t18-hub";
const OP_TIMEOUT_MS = 20_000;
const WALL_BUDGET_MS = 60_000;

const log = (...a) => console.log(new Date().toISOString(), ...a);
const withTimeout = (p, ms = OP_TIMEOUT_MS) =>
  Promise.race([
    p,
    new Promise((_, rej) =>
      setTimeout(() => rej(Object.assign(new Error("BENCH_OP_TIMEOUT"), { code: "BENCH_OP_TIMEOUT" })), ms),
    ),
  ]);

const machine = {
  cpu: os.cpus()[0].model,
  cores: os.cpus().length,
  node: process.version,
  endpoint: `sb://127.0.0.1:${EH_PORT}`,
};

// ---- liveness probe: loud SKIP, never restart ------------------------------
async function substrateUp() {
  try {
    const r = await fetch(`${ARM}/providers?api-version=2099-01-01`, {
      signal: AbortSignal.timeout(5000),
    });
    r.body?.cancel().catch(() => {});
    return r.status < 500;
  } catch {
    return false;
  }
}

// ---- per-host dev SAS key (substrate.sh contract) --------------------------
const perHostKey = () =>
  Buffer.from(
    crypto.createHash("sha256").update(`${os.hostname()}smalt-dev-sb`).digest(),
  ).toString("base64");

const cs = (key) =>
  `Endpoint=sb://127.0.0.1:${EH_PORT};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${key};EntityPath=${HUB};UseDevelopmentEmulator=true`;

function emitRow(row) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
}

// ===========================================================================
async function main() {
  if (!(await substrateUp())) {
    log("SKIP: live substrate down (9443 not serving) — lane law: never restart");
    emitRow({
      lane: "scvd-t18", surface: "eventhubs", op: "skip-substrate-down", n: 0,
      ops_per_sec: 0, p50_ms: 0, p95_ms: 0, p99_ms: 0, errors: 0, wall_ms: 0,
      machine, standing: "SKIP",
    });
    process.exit(3);
  }

  const require2 = createRequire(path.join(TS_DIR, "package.json"));
  const { EventHubProducerClient } = require2("@azure/event-hubs");
  const ehPkg = require2(path.join(TS_DIR, "node_modules/@azure/event-hubs/package.json"));
  const rheaPkg = require2(path.join(TS_DIR, "node_modules/rhea/package.json"));
  machine.sdk = `@azure/event-hubs@${ehPkg.version}`;
  machine.rhea = `rhea@${rheaPkg.version}`;

  // admit-key probe: one throwaway producer proves which key the EH plane takes
  let client = null, usedKey = "";
  for (const key of [perHostKey(), "ws8sharedkey"]) {
    try {
      const probe = new EventHubProducerClient(cs(key), HUB, {
        retryOptions: { maxRetries: 0, timeoutInMs: 15_000 },
      });
      const batch = await probe.createBatch();
      batch.tryAdd({ body: "t18-keyprobe" });
      await withTimeout(probe.sendBatch(batch), 15_000);
      await probe.close().catch(() => {});
      client = new EventHubProducerClient(cs(key), HUB, {
        retryOptions: { maxRetries: 0, timeoutInMs: 20_000 },
      });
      usedKey = key === perHostKey() ? "per-host" : "ws8sharedkey";
      break;
    } catch (e) {
      log(`key ${key.slice(0, 8)} rejected: ${String(e?.message ?? e).slice(0, 120)}`);
    }
  }
  if (!client) {
    log("SKIP: EH plane not admitting either known dev key — never restart");
    emitRow({
      lane: "scvd-t18", surface: "eventhubs", op: "skip-key-refused", n: 0,
      ops_per_sec: 0, p50_ms: 0, p95_ms: 0, p99_ms: 0, errors: 0, wall_ms: 0,
      machine, standing: "SKIP",
    });
    process.exit(3);
  }
  log(`EH key admitted: ${usedKey}; hub=${HUB} concurrency=${CONCURRENCY} sends/worker=${SENDS_PER_WORKER}`);
  await client.close().catch(() => {});
  client = null;

  const connCs = cs(perHostKey() /* recomputed per worker below */);
  const lat = [];
  let acks = 0, errors = 0, lastErr = "";

  const worker = async (w) => {
    const key = crypto.randomBytes(0) && perHostKey();
    const producer = new EventHubProducerClient(cs(key), HUB, {
      retryOptions: { maxRetries: 0, timeoutInMs: 20_000 },
    });
    try {
      for (let c = 0; c < SENDS_PER_WORKER; c++) {
        const s = performance.now();
        try {
          const batch = await withTimeout(producer.createBatch());
          batch.tryAdd({
            body: crypto.randomBytes(1024).toString("hex"),
            properties: { messageId: `t18-${w}-${c}` },
          });
          await withTimeout(producer.sendBatch(batch));
          lat.push(performance.now() - s);
          acks++;
        } catch (e) {
          lat.push(performance.now() - s);
          errors++;
          lastErr = `w${w}#${c}: ${String(e?.message ?? e).slice(0, 160)}`;
        }
      }
    } finally {
      await producer.close().catch(() => {});
    }
  };

  const t0 = Date.now();
  await Promise.all(Array.from({ length: CONCURRENCY }, (_, w) => worker(w)));
  const wallMs = Date.now() - t0;

  const sorted = [...lat].sort((a, b) => a - b);
  const pct = (p) => {
    if (!sorted.length) return 0;
    const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
    return Number(sorted[Math.max(0, i)].toFixed(3));
  };
  const standing = errors === 0 && acks === CONCURRENCY * SENDS_PER_WORKER && wallMs <= WALL_BUDGET_MS
    ? "PASS"
    : "FAIL";
  const row = {
    lane: "scvd-t18", surface: "eventhubs", op: `send-c${CONCURRENCY}`,
    n: acks, ops_per_sec: Number((acks / (wallMs / 1000)).toFixed(1)),
    p50_ms: pct(50), p95_ms: pct(95), p99_ms: pct(99),
    errors, wall_ms: wallMs, wall_budget_ms: WALL_BUDGET_MS,
    concurrency: CONCURRENCY, sends_per_worker: SENDS_PER_WORKER, total_sends: CONCURRENCY * SENDS_PER_WORKER,
    sas_key: usedKey, hub: HUB, machine, standing,
    ...(lastErr ? { last_err: lastErr.slice(0, 200) } : {}),
  };
  emitRow(row);
  log(`EH n=${acks}/${CONCURRENCY * SENDS_PER_WORKER} ops/s=${row.ops_per_sec} p50=${row.p50_ms}ms p95=${row.p95_ms}ms p99=${row.p99_ms}ms errors=${errors} wall=${wallMs}ms standing=${standing}${lastErr ? " lastErr=" + lastErr : ""}`);
  process.exit(standing === "PASS" ? 0 : 1);
}

main().catch((e) => {
  log("FATAL", e?.stack ?? String(e));
  emitRow({
    lane: "scvd-t18", surface: "eventhubs", op: "fatal", n: 0, ops_per_sec: 0,
    p50_ms: 0, p95_ms: 0, p99_ms: 0, errors: 1, wall_ms: 0, machine,
    standing: "FAIL", last_err: String(e?.message ?? e).slice(0, 200),
  });
  process.exit(1);
});
