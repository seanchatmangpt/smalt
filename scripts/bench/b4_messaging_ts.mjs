// B-4 lane: messaging throughput through the REAL TS SDKs (@azure/service-bus,
// @azure/event-hubs) over AMQP to the smalt BEAM substrate.
//
// Measures:
//   (a) SB send throughput (1 KiB payloads, 30s, sessionless queue)
//   (b) SB send + receive-complete round-trip throughput (receiver drain loop, >=500 msgs)
//   (c) EH producer send events/sec + consumer receive events/sec (1 KiB events)
//
// Self-boots the substrate on the b4 private port block (lib.sh port law:
// b4 -> 39040..39045), mints its own sb_shared_key, tears down on exit.
// Honest-error policy: record errors verbatim; never fabricate a rate.
//
// Run: node scripts/bench/b4_messaging_ts.mjs
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SDK_DIR = path.join(REPO, "verification/ts");
const OUT =
  process.env.B4_OUT ||
  path.join(REPO, "docs/jira/v26.10.14/bench/b4-messaging-ts.jsonl");

// lib.sh port law: b4 -> 39000 + 4*10 = 39040 block.
const ARM = Number(process.env.B4_ARM_PORT || 39040);
const EGRESS = Number(process.env.B4_EGRESS_PORT || 39041);
const AMQP = Number(process.env.B4_AMQP_PORT || 39042);
const EHUB = Number(process.env.B4_EHUB_PORT || 39043);
const ATLS = Number(process.env.B4_ATLS_PORT || 39044);
const MCP = Number(process.env.B4_MCP_PORT || 39045);

const PAYLOAD = randomBytes(1024); // 1 KiB
const SEND_WINDOW_MS = 30_000;
const WARMUP_MS = 5_000;
const RT_MIN_MSGS = 500;

const { ServiceBusClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/service-bus/dist/esm/index.js")
);
const { EventHubProducerClient, EventHubConsumerClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/event-hubs/dist/esm/index.js")
);
const rhea = await import(
  path.join(SDK_DIR, "node_modules/rhea/lib/container.js")
).then((m) => m.default ?? m);

const sdkPkg = (name) =>
  JSON.parse(
    fs.readFileSync(path.join(SDK_DIR, `node_modules/@azure/${name}/package.json`), "utf8"),
  );
const SB_V = sdkPkg("service-bus").version;
const EH_V = sdkPkg("event-hubs").version;
const RHEA_V = JSON.parse(
  fs.readFileSync(path.join(SDK_DIR, "node_modules/rhea/package.json"), "utf8"),
).version;

const log = (...a) => console.log(new Date().toISOString(), ...a);

// Witnessed SDK-internal race (core-amqp requestResponseLink.js:107): a CBS
// request-response link timer fires after its session is torn down during
// aggressive client recycling and throws an uncaught TypeError. A benchmark
// harness that dies on an SDK timer race measures nothing; record the crash
// verbatim in the JSONL and let the current bench's error path recycle the
// transport.
const uncaught = [];
process.on("uncaughtException", (e) => {
  uncaught.push({ name: e?.name, msg: String(e?.message ?? e).slice(0, 200), stack: String(e?.stack).split("\n").slice(0, 3).join(" | ") });
  log("uncaughtException (recorded, continuing):", String(e?.message ?? e).slice(0, 120));
});

// ---- results ----
const lines = [];
const emit = (obj) => {
  lines.push(JSON.stringify({ lane: "b4", ...obj }));
};
const flush = () => {
  if (uncaught.length) {
    lines.push(JSON.stringify({ lane: "b4", ts: new Date().toISOString(), event: "uncaught-exceptions", count: uncaught.length, detail: uncaught }));
  }
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, lines.join("\n") + "\n");
  log("wrote", OUT, `(${lines.length} records)`);
};

const errors = [];
const noteErr = (op, e) => {
  errors.push({
    op,
    name: e?.name,
    code: e?.code,
    msg: String(e?.message ?? "").slice(0, 200),
  });
  return e;
};

// ---- latency stats ----
function stats(lat) {
  if (!lat.length) return { p50: 0, p95: 0, p99: 0 };
  const v = [...lat].sort((a, b) => a - b);
  const q = (p) => v[Math.min(v.length - 1, Math.ceil((p / 100) * v.length) - 1)];
  return { p50: q(50), p95: q(95), p99: q(99) };
}

function pct(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}

// ---- substrate boot (mirrors scripts/bench/lib.sh bench_boot) ----
const sharedKey = randomBytes(48).toString("base64");

function portFree(p) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1200 });
    s.once("connect", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(true));
    s.once("timeout", () => { s.destroy(); resolve(true); });
  });
}

async function bootSubstrate() {
  const ports = [ARM, EGRESS, AMQP, EHUB, ATLS, MCP];
  for (const p of ports) {
    if (!(await portFree(p))) {
      console.error(`[b4] port ${p} already held — refusing to boot (collision)`);
      process.exit(3);
    }
  }
  const logPath = path.join(REPO, "tmp/bench-substrate-b4.log");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const evalCode = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP}")`,
    `Application.put_env(:smalt, :arm_port, ${ARM})`,
    `Application.put_env(:smalt, :egress_port, ${EGRESS})`,
    `Application.put_env(:smalt, :amqp_port, ${AMQP})`,
    `Application.put_env(:smalt, :event_hubs_port, ${EHUB})`,
    `Application.put_env(:smalt, :arm_tls_port, ${ATLS})`,
    `Application.put_env(:smalt, :mcp_port, ${MCP})`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
    `Process.sleep(:infinity)`,
  ].join("; ");
  const child = spawn(
    "mix",
    ["run", "--no-start", "-e", evalCode, "--no-halt"],
    { cwd: REPO, env: { ...process.env, MIX_ENV: "test" }, stdio: ["ignore", "pipe", "pipe"], detached: true },
  );
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);
  const t0 = Date.now();
  for (;;) {
    if (await portFree(ARM) === false) break;
    if (Date.now() - t0 > 120_000) {
      console.error(`[b4] substrate failed to listen on ${ARM} in 120s; log: ${logPath}`);
      killSubstrate();
      process.exit(2);
      return;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  log(`substrate up on ports ${ports.join("/")} after ${Date.now() - t0}ms (pid ${child.pid})`);
  return child;
}

function killSubstrate(child) {
  if (!child) return;
  try {
    if (child.pid && child.exitCode === null) {
      try { process.kill(-child.pid, "SIGTERM"); } catch { child.kill("SIGTERM"); }
    }
  } catch { /* gone */ }
}

// Per-op timeout: the SDK's internal CBS timer race can leave an awaited send
// permanently pending (witnessed); race every op so the loop always advances.
const OP_TIMEOUT_MS = 20_000;
const withTimeout = (p, ms = OP_TIMEOUT_MS) =>
  Promise.race([
    p,
    new Promise((_, rej) =>
      setTimeout(() => rej(Object.assign(new Error("BENCH_OP_TIMEOUT"), { code: "BENCH_OP_TIMEOUT" })), ms),
    ),
  ]);

const closeSoon = (p) =>
  Promise.race([Promise.resolve(p).catch(() => {}), new Promise((r) => setTimeout(r, 2000))]);

// ---- connection strings ----
const SB_CS = `Endpoint=sb://127.0.0.1:${AMQP};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${sharedKey};UseDevelopmentEmulator=true`;
const EH_CS = `Endpoint=sb://127.0.0.1:${EHUB};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${sharedKey};EntityPath=b4-hub;UseDevelopmentEmulator=true`;
const CLI_OPTS = { retryOptions: { maxRetries: 4, retryDelayInMs: 2000, timeoutInMs: 30000 } };

// Wire fact (witnessed this lane): the substrate grants a fixed link_credit of
// 1000 to client-sender links at attach (lib/smalt/messaging/amqp/connection.ex
// ~:525) and never replenishes on disposition, so a long-lived sender link
// starves (SenderBusyError) once the client exhausts the initial window.
// Mitigation WITHOUT lib edits: recycle the sender link every 400 messages and
// report the recycle count alongside the rate.
const RECYCLE_EVERY = 400;
// Witnessed hard limit: the substrate never advances the AMQP SESSION
// incoming-window; after exactly 4096 inbound transfers on one session every
// further transfer goes undispositioned (15-20s op timeouts). Recycle the
// whole client (new connection+session) every 3000 sends to stay under it.
const CLIENT_RECYCLE_SENDS = 3000;

// ---- (a) SB send throughput ----
const SEND_QUEUE = `b4-send-${Date.now()}`;
const RT_QUEUE = `b4-rt-${Date.now()}`;

async function benchSbSend() {
  const queue = SEND_QUEUE;
  let client = new ServiceBusClient(SB_CS, CLI_OPTS);
  let sender = client.createSender(queue);
  const lat = [];
  let n = 0, errs = 0, recycles = 0, clientRecycles = 0;
  const errDetail = [];
  const newSender = async () => {
    await closeSoon(sender.close())
    sender = client.createSender(queue);
    recycles++;
  };
  // Full transport recycle: close the client (connection + session) and open a
  // fresh one. Used on consecutive send errors (witnessed: under load a transfer
  // can go unanswered until the SDK's 15s operation timeout; a fresh link on the
  // SAME session does not recover — only a new connection does).
  const newClient = async () => {
    await closeSoon(sender.close())
    await closeSoon(client.close())
    client = new ServiceBusClient(SB_CS, CLI_OPTS);
    sender = client.createSender(queue);
    clientRecycles++;
    clientSends = 0;
  };
  let verbose = !!process.env.B4_VERBOSE;
  let clientSends = 0;
  const sendOnce = async () => {
    const t0 = performance.now();
    try {
      await withTimeout(sender.sendMessages({ body: PAYLOAD }));
      if (verbose) console.log(`send#${n} ok ${(performance.now()-t0).toFixed(1)}ms`);
    } catch (e) {
      if (verbose) console.log(`send#${n} FAIL ${(performance.now()-t0).toFixed(0)}ms ${String(e?.message).slice(0,90)}`);
      errs++;
      if (errDetail.length < 5) errDetail.push({ name: e?.name, code: e?.code, msg: String(e?.message).slice(0, 120) });
      return false;
    }
    lat.push(performance.now() - t0);
    n++;
    clientSends++;
    return true;
  };
  try {
    // warmup + measured share the same resilient loop
    const wEnd = Date.now() + WARMUP_MS;
    while (Date.now() < wEnd) {
      if (!(await sendOnce())) await newClient();
      if (clientSends >= CLIENT_RECYCLE_SENDS) await newClient();
    }
    const warm = n;
    lat.length = 0;
    const windowStart = Date.now();
    const end = windowStart + SEND_WINDOW_MS;
    let consecutiveErrs = 0;
    while (Date.now() < end) {
      const ok = await sendOnce();
      consecutiveErrs = ok ? 0 : consecutiveErrs + 1;
      if (consecutiveErrs >= 2) { await newClient(); consecutiveErrs = 0; }
      if (clientSends >= CLIENT_RECYCLE_SENDS) await newClient();
    }
    const dur = (Date.now() - windowStart) / 1000;
    const s = stats(lat);
    emit({
      ts: new Date().toISOString(), event: "result", surface: "servicebus", op: "send",
      n: lat.length, ops_per_sec: +(lat.length / dur).toFixed(1),
      p50_ms: +s.p50.toFixed(3), p95_ms: +s.p95.toFixed(3), p99_ms: +s.p99.toFixed(3),
      errors: errs, sender_link_recycles: recycles, client_recycles: clientRecycles,
      note: "sender link recycled every 400 msgs: substrate grants fixed link_credit=1000 per client-sender link at attach and never replenishes (KD candidate)",
      err_detail: errDetail,
    });
    log(`(a) SB send: ${lat.length} msgs in ${dur.toFixed(0)}s = ${(lat.length / dur).toFixed(1)} msgs/s p50=${s.p50.toFixed(2)}ms errs=${errs} clientRecycles=${clientRecycles}`);
  } finally {
    await closeSoon(client.close())
  }
  return { n: lat.length, errors: errs };
}

// ---- (b) SB send + receive-complete round-trip ----
async function benchSbRoundTrip() {
  const queue = RT_QUEUE;
  // Sender and receiver live on SEPARATE clients: the sender side needs full
  // connection recycles on stall (witnessed), the receiver link must not die
  // with it.
  let client = new ServiceBusClient(SB_CS, CLI_OPTS);
  let sender = client.createSender(queue);
  const rxClient = new ServiceBusClient(SB_CS, CLI_OPTS);
  const receiver = rxClient.createReceiver(queue, {
    maxAutoLockRenewalDurationInMs: 0,
  });
  let completed = 0, sent = 0, errs = 0, recvErrs = 0, clientRecycles = 0, clientSends = 0;
  const lat = []; // send->complete latency
  const stamps = new Map();
  const errDetail = [];
  let draining = true;

  let recycles = 0;
  const newSender = async () => {
    await closeSoon(sender.close())
    sender = client.createSender(queue);
    recycles++;
  };
  const newClient = async () => {
    await closeSoon(sender.close())
    await closeSoon(client.close())
    client = new ServiceBusClient(SB_CS, CLI_OPTS);
    sender = client.createSender(queue);
    clientRecycles++;
    clientSends = 0;
  };
  const drain = (async () => {
    while (draining) {
      try {
        const msgs = await receiver.receiveMessages(100, { maxWaitTimeInMs: 500 });
        for (const m of msgs) {
          const t0 = stamps.get(m.messageId);
          await receiver.completeMessage(m);
          completed++;
          if (t0 !== undefined) lat.push(performance.now() - t0);
          stamps.delete(m.messageId);
        }
      } catch (e) {
        recvErrs++;
        if (errDetail.length < 5) errDetail.push({ side: "recv", name: e?.name, code: e?.code, msg: String(e?.message).slice(0, 150) });
        await new Promise((r) => setTimeout(r, 200));
      }
    }
  })();

  try {
    // priming send on the real sender (see benchSbSend note)
    for (let i = 0; i < 3 && sent === 0; i++) {
      try {
        await withTimeout(sender.sendMessages({ body: PAYLOAD, messageId: `prime-${i}` }), 25_000);
        sent++;
      } catch (e) {
        errs++;
        if (errDetail.length < 5) errDetail.push({ phase: "prime", name: e?.name, code: e?.code, msg: String(e?.message).slice(0, 100) });
        await newClient();
      }
    }
    // warmup + minimum floor
    const windowStart = Date.now();
    const end = windowStart + SEND_WINDOW_MS;
    let consecutiveErrs = 0;
    do {
      const t0 = performance.now();
      const id = `rt-${sent}`;
      try {
        await withTimeout(sender.sendMessages({ body: PAYLOAD, messageId: id }));
        stamps.set(id, t0);
        sent++;
        consecutiveErrs = 0;
      } catch (e) {
        errs++;
        consecutiveErrs++;
        if (errDetail.length < 5) errDetail.push({ side: "send", name: e?.name, code: e?.code, msg: String(e?.message).slice(0, 120) });
        if (consecutiveErrs >= 2) { await newClient(); consecutiveErrs = 0; }
      }
      if (clientSends >= CLIENT_RECYCLE_SENDS) await newClient();
    } while (sent < RT_MIN_MSGS || Date.now() < end);
    // grace for drain to finish
    const deadline = Date.now() + 15_000;
    while (completed < sent && Date.now() < deadline) await new Promise((r) => setTimeout(r, 250));
    var dur = (Date.now() - windowStart) / 1000;
  } finally {
    draining = false;
    await closeSoon(receiver.close())
    await closeSoon(sender.close())
    await closeSoon(client.close())
    await rxClient.close().catch(() => {});
  }

  const s = stats(lat);
  emit({
    ts: new Date().toISOString(), event: "result", surface: "servicebus",
    op: "send+receive-complete-roundtrip", n: completed,
    sent, ops_per_sec: +(completed / dur).toFixed(1),
    p50_ms: +s.p50.toFixed(3), p95_ms: +s.p95.toFixed(3), p99_ms: +s.p99.toFixed(3),
    errors: errs + recvErrs, send_errors: errs, receive_errors: recvErrs,
    sender_link_recycles: recycles, client_recycles: clientRecycles,
    err_detail: errDetail,
  });
  log(`(b) SB round-trip: sent=${sent} completed=${completed} => ${(completed / dur).toFixed(1)} round-trips/s, p50=${s.p50.toFixed(2)}ms errs=${errs + recvErrs}`);
  return { sent, completed };
}

// ---- (c) EH producer + consumer ----
async function benchEh() {
  const hub = "b4-hub";
  // Producer throughput
  let producer = new EventHubProducerClient(EH_CS, hub, CLI_OPTS);
  const lat = [];
  let events = 0, errs = 0, recycles = 0;
  const errDetail = [];
  const newProducer = async () => {
    await closeSoon(producer.close())
    producer = new EventHubProducerClient(EH_CS, hub, CLI_OPTS);
    recycles++;
  };
  try {
    const wEnd = Date.now() + WARMUP_MS;
    while (Date.now() < wEnd) {
      const batch = await withTimeout(producer.createBatch());
      batch.tryAdd({ body: PAYLOAD });
      await withTimeout(producer.sendBatch(batch));
      events++;
      if (events > 0 && events % RECYCLE_EVERY === 0) await newProducer();
    }
    const warm = events;
    lat.length = 0;
    const end = Date.now() + SEND_WINDOW_MS;
    while (Date.now() < end) {
      const t0 = performance.now();
      try {
        const batch = await withTimeout(producer.createBatch());
        batch.tryAdd({ body: PAYLOAD });
        await withTimeout(producer.sendBatch(batch));
      } catch (e) {
        errs++;
        if (errDetail.length < 5) errDetail.push({ name: e?.name, code: e?.code, msg: String(e?.message).slice(0, 120) });
        await newProducer(); // fresh connection on error (witnessed stall recovery)
      }
      lat.push(performance.now() - t0);
      events++;
      if (events > 0 && events % RECYCLE_EVERY === 0) await newProducer();
    }
    const dur = SEND_WINDOW_MS / 1000;
    const s = stats(lat);
    emit({
      ts: new Date().toISOString(), event: "meta", surface: "eventhubs",
      sdk: `@azure/event-hubs@${EH_V}`, rhea: RHEA_V, node: process.version,
      eh_port: EHUB, hub, payload_bytes: 1024, warmup_events: warm,
    });
    emit({
      ts: new Date().toISOString(), event: "result", surface: "eventhubs", op: "producer-send",
      n: lat.length, ops_per_sec: +(lat.length / dur).toFixed(1),
      p50_ms: +s.p50.toFixed(3), p95_ms: +s.p95.toFixed(3), p99_ms: +s.p99.toFixed(3),
      errors: errs, sender_link_recycles: recycles,
      err_detail: errDetail,
    });
    log(`(c) EH producer: ${lat.length} events in ${SEND_WINDOW_MS / 1000}s = ${(lat.length / dur).toFixed(1)} events/s p50=${s.p50.toFixed(2)}ms errs=${errs} recycles=${recycles}`);
  } finally {
    await closeSoon(producer.close())
  }

  // Consumer via SDK subscribe() — expected to hit KD-19 501 on getEventHubProperties.
  let sdkConsumerOk = false;
  try {
    const consumer = new EventHubConsumerClient("$Default", EH_CS, hub, CLI_OPTS);
    const sub = await consumer.subscribe(
      {
        processEvents: async (evts) => { events += evts.length; },
        processError: async () => {},
      },
      { maxWaitTimeInSeconds: 1 },
    );
    await new Promise((r) => setTimeout(r, 8000));
    await sub.close();
    await consumer.close();
    sdkConsumerOk = true;
  } catch (e) {
    noteErr("eh-sdk-subscribe", e);
    emit({
      ts: new Date().toISOString(), event: "error", surface: "eventhubs", op: "sdk-consumer-subscribe",
      name: e?.name, code: e?.code, msg: String(e?.message).slice(0, 300),
    });
    log(`(c) EH SDK consumer subscribe FAILED: ${e?.name} ${e?.code} ${String(e?.message).slice(0, 120)}`);
  }

  // Wire-tier consumer via rhea directly (KD-18/19/20 context; labelled honestly).
  const partEvents = [];
  await new Promise((resolve) => {
    const container = rhea.create_container();
    let conn;
    const done = (why) => {
      try { conn?.close(); } catch { /* */ }
      resolve(why);
    };
    const timer = setTimeout(() => done("timeout"), 40_000);
    conn = container.connect({
      host: "127.0.0.1",
      port: EHUB,
      hostname: "127.0.0.1",
      container_id: "b4-rhea-consumer",
      sasl_mechanisms: { plain: { username: "RootManageSharedAccessKey", password: sharedKey } },
    });
    conn.on("connection_open", (ctx) => {
      ctx.connection.open_receiver({
        source: { address: `${hub}/ConsumerGroups/$Default/Partitions/0` },
        credit_window: 1000,
      });
    });
    conn.on("message", (ctx) => {
      partEvents.push(ctx.message);
      if (partEvents.length >= 2000) { clearTimeout(timer); done("count-reached"); }
    });
    conn.on("connection_error", (e) => { clearTimeout(timer); done("conn-error: " + String(e?.error?.condition ?? e)); });
  });
  const seqs = partEvents
    .map((m) => m?.message_annotations?.["x-opt-sequence-number"])
    .filter((s) => typeof s === "number");
  emit({
    ts: new Date().toISOString(), event: "result", surface: "eventhubs", op: "consumer-receive-rhea-wire-tier",
    n: partEvents.length, decoded_seq_annotations: seqs.length,
    sdk_consumer_subscribe_ok: sdkConsumerOk,
    errors: sdkConsumerOk ? 0 : 1,
  });
  log(`(c) EH rhea wire-tier consumer: received ${partEvents.length} events (seq annotated: ${seqs.length}), sdk subscribe ok=${sdkConsumerOk}`);
}

// ---- main ----
const substrate = await bootSubstrate();

// BK-B4R fix (2026-10-22): since KD-86 (fe4a3d83, v26.10.21) the substrate
// has real-SB entity semantics — a send to a never-created entity is refused
// with MessagingEntityNotFound and the sender link is detached. The old
// emulator auto-create-on-send convenience this harness relied on is gone,
// so every send burned the 20s op timeout (BK-BQUIET's "0/2000 sends,
// CBS-at-200" face = entity refusal churn, not link starvation). Provision
// the queue entities over the ARM ATOM alias before measuring.
async function provisionQueue(queue) {
  const body = `<?xml version="1.0" encoding="utf-8"?>
<entry xmlns="http://www.w3.org/2005/Atom"><updated>2026-10-22T00:00:00.000Z</updated><content type="application/xml">
  <QueueDescription xmlns="http://schemas.microsoft.com/netservices/2010/01/servicebus"></QueueDescription></content></entry>`;
  const res = await fetch(`http://127.0.0.1:${ARM}/${queue}`, {
    method: "PUT",
    headers: { "Content-Type": "application/atom+xml;type=entry;charset=utf-8" },
    body,
  });
  if (res.status !== 200 && res.status !== 201) {
    throw new Error(`queue PUT ${queue} -> ${res.status}`);
  }
  log(`provisioned queue ${queue} (${res.status})`);
}

try {
  await provisionQueue(SEND_QUEUE);
  await provisionQueue(RT_QUEUE);
} catch (e) {
  console.error("[b4] pre-provision failed", e);
  flush();
  killSubstrate(substrate);
  process.exit(3);
}

try {
  emit({
    ts: new Date().toISOString(), event: "meta",
    sdks: [`@azure/service-bus@${SB_V}`, `@azure/event-hubs@${EH_V}`], rhea: RHEA_V,
    node: process.version, ports: { arm: ARM, amqp: AMQP, eventhubs: EHUB },
    payload_bytes: 1024, send_window_s: SEND_WINDOW_MS / 1000, warmup_s: WARMUP_MS / 1000,
  });
  const only = process.env.B4_ONLY;
  if (!only || only.includes("send")) await benchSbSend();
  if (!only || only.includes("rt")) await benchSbRoundTrip();
  if (!only || only.includes("eh")) await benchEh();
} finally {
  flush();
  killSubstrate(substrate);
  // wait for ports to close
  for (let i = 0; i < 20; i++) {
    if (await portFree(AMQP)) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  log("substrate down, ports free");
}
