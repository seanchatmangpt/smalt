// C-2 lane: Service Bus -> Cosmos fan-in (messaging drain to durable store —
// the premium-messaging + RU pattern) via real @azure/service-bus +
// @azure/cosmos over the smalt BEAM substrate.
//
// Phases:
//   (1) pipeline: preload 500 msgs via SDK send (KD-20: sender credit
//       starvation means preload is the SDK tier at ~50/s witnessed; recorded
//       per run), then consumer loop receive -> cosmos upsert -> complete.
//   (2) backpressure: same, cosmos upserts artificially delayed 50 ms; measure
//       drain time + depth decay (depth = preloaded - received, counted at the
//       SDK tier).
//   (3) session fan-in: requires-session queue (ARM-provisioned), 10 sessions
//       x 20 msgs, per-session ordered upserts; sessions/s + ordering check.
//   (4) interference: phase-1 pipeline concurrent with cosmos point-reads;
//       delta vs isolated phase-1.
//
// Self-boots the substrate on the c2 private port block. Port law note: the
// lib.sh law only assigns b1..b12 (39010..39125); the c-family runs above it —
// c2 -> 39220..39225 (c-law band 39200+, ephemeral range starts 49152).
// Honest-error policy: record errors verbatim; never fabricate a rate.
//
// Run: node scripts/bench/c2_sb_cosmos.mjs
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SDK_DIR = path.join(REPO, "verification/ts");
const OUT =
  process.env.C2_OUT ||
  path.join(REPO, "docs/jira/v26.10.14/bench/c2-sb-cosmos.jsonl");

// c2 port block (see header note).
const ARM = Number(process.env.C2_ARM_PORT || 39220);
const EGRESS = Number(process.env.C2_EGRESS_PORT || 39221); // cosmos plane
const AMQP = Number(process.env.C2_AMQP_PORT || 39222);
const EHUB = Number(process.env.C2_EHUB_PORT || 39223);
const ATLS = Number(process.env.C2_ATLS_PORT || 39224);
const MCP = Number(process.env.C2_MCP_PORT || 39225);

const MSGS = 500;              // preload size, phases 1/2/4
const SESSIONS = 10;
const SESSION_MSGS = 20;
const UPSERT_CONCURRENCY = 8;  // bounded upsert parallelism in the drain loop
const READ_CONCURRENCY = 4;    // interference point-read workers
const BACKPRESSURE_DELAY_MS = 50;
const OP_TIMEOUT_MS = 25_000;

const { ServiceBusClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/service-bus/dist/esm/index.js")
);
const { CosmosClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/cosmos/dist/esm/index.js")
);

const sdkPkg = (p) =>
  JSON.parse(fs.readFileSync(path.join(SDK_DIR, `node_modules/@azure/${p}/package.json`), "utf8"));
const SB_V = sdkPkg("service-bus").version;
const COSMOS_V = sdkPkg("cosmos").version;

const log = (...a) => console.log(new Date().toISOString(), ...a);

// SDK-internal timer races (core-amqp requestResponseLink) can throw on the
// event loop during aggressive client recycling; record verbatim, keep benching.
const uncaught = [];
process.on("uncaughtException", (e) => {
  uncaught.push({ name: e?.name, msg: String(e?.message ?? e).slice(0, 200) });
  log("uncaughtException (recorded, continuing):", String(e?.message ?? e).slice(0, 120));
});

const lines = [];
const emit = (obj) => lines.push(JSON.stringify({ lane: "c2", ts: new Date().toISOString(), ...obj }));
const flush = () => {
  if (uncaught.length)
    lines.push(JSON.stringify({ lane: "c2", ts: new Date().toISOString(), event: "uncaught-exceptions", count: uncaught.length, detail: uncaught }));
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, lines.join("\n") + "\n");
  log("wrote", OUT, `(${lines.length} records)`);
};

const errors = [];
const noteErr = (op, e) => {
  errors.push({ op, name: e?.name, code: e?.code, msg: String(e?.message ?? "").slice(0, 200) });
};

function pct(sorted, p) {
  if (!sorted.length) return 0;
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}
const stats = (lat) => {
  const v = [...lat].sort((a, b) => a - b);
  return { p50: pct(v, 50), p95: pct(v, 95), p99: pct(v, 99), mean: lat.length ? lat.reduce((a, b) => a + b, 0) / lat.length : 0 };
};

const withTimeout = (p, ms = OP_TIMEOUT_MS) =>
  Promise.race([
    p,
    new Promise((_, rej) =>
      setTimeout(() => rej(Object.assign(new Error("BENCH_OP_TIMEOUT"), { code: "BENCH_OP_TIMEOUT" })), ms),
    ),
  ]);

const closeSoon = (p) =>
  Promise.race([Promise.resolve(p).catch(() => {}), new Promise((r) => setTimeout(r, 2000))]);

// ---- substrate boot (mirrors b4 pattern) ----
const sharedKey = crypto.randomBytes(48).toString("base64");
const COSMOS_KEY = crypto.randomBytes(32).toString("hex");

function portFree(p) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1200 });
    s.once("connect", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(true));
    s.once("timeout", () => { s.destroy(); resolve(true); });
  });
}

let substrateChild = null;
// Self-heal: lanes share the machine; an external SIGTERM (another lane's
// cleanup sweep) can take the substrate down mid-run. Before each phase,
// verify the ARM front door is still listening; if not, boot a fresh one.
async function ensureSubstrate() {
  if ((await portFree(ARM)) === false) return; // something is listening — alive
  log("substrate down (external kill?) — rebooting");
  killSubstrate(substrateChild);
  substrateChild = await bootSubstrate();
  // cosmos state lives in the substrate process — re-create db/container
  database = undefined;
  await initCosmos();
}

async function bootSubstrate() {
  const ports = [ARM, EGRESS, AMQP, EHUB, ATLS, MCP];
  for (const p of ports) {
    if (!(await portFree(p))) {
      console.error(`[c2] port ${p} already held — refusing to boot (collision)`);
      process.exit(3);
    }
  }
  const logPath = path.join(REPO, "tmp/bench-substrate-c2.log");
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
  const child = spawn("mix", ["run", "--no-start", "-e", evalCode, "--no-halt"], {
    cwd: REPO,
    env: { ...process.env, MIX_ENV: "test" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);
  const t0 = Date.now();
  for (;;) {
    if ((await portFree(ARM)) === false) break;
    if (Date.now() - t0 > 120_000) {
      console.error(`[c2] substrate failed to listen on ${ARM} in 120s; log: ${logPath}`);
      killSubstrate(child);
      process.exit(2);
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

// ---- connection strings / clients ----
const SB_CS = `Endpoint=sb://127.0.0.1:${AMQP};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${sharedKey};UseDevelopmentEmulator=true`;
const CLI_OPTS = { retryOptions: { maxRetries: 4, retryDelayInMs: 2000, timeoutInMs: 30000 } };

const cosmos = new CosmosClient({
  endpoint: `http://127.0.0.1:${EGRESS}`,
  key: COSMOS_KEY,
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});
const DB_ID = `c2db-${Date.now()}`;
let database, container;
async function initCosmos() {
  ({ database } = await cosmos.databases.createIfNotExists({ id: DB_ID }));
  ({ container } = await database.containers.createIfNotExists({
    id: "c2", partitionKey: { paths: ["/pk"] },
  }));
  log("cosmos db/container ready", DB_ID);
}

// ---- ARM queue provisioning (the admitted surface; Python-admin shape 404s) ----
const ARM_BASE = `http://127.0.0.1:${ARM}/subscriptions/c2-sub/resourceGroups/c2-rg/providers/Microsoft.ServiceBus/namespaces/c2-ns/queues`;
let nsReady = false;
async function ensureNamespace() {
  if (nsReady) return;
  const put = async (path, body) => {
    const r = await fetch(`http://127.0.0.1:${ARM}${path}?api-version=2021-04-01`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    if (r.status !== 200 && r.status !== 201)
      throw new Error(`ARM PUT ${path}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  };
  await put("/subscriptions/c2-sub/resourceGroups/c2-rg", { location: "eastus" });
  await put(
    "/subscriptions/c2-sub/resourceGroups/c2-rg/providers/Microsoft.ServiceBus/namespaces/c2-ns",
    { location: "eastus", skuName: "Standard" },
  );
  nsReady = true;
}
async function provisionQueue(name, props = {}) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await ensureNamespace();
      const r = await fetch(`${ARM_BASE}/${name}?api-version=2021-04-01`, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ location: "eastus", properties: props }),
      });
      if (r.status === 200 || r.status === 201) return name;
      throw new Error(`ARM PUT queue ${name}: ${r.status} ${(await r.text()).slice(0, 200)}`);
    } catch (e) {
      noteErr("provisionQueue", e);
      await ensureSubstrate();
      if (attempt === 3) throw e;
      await new Promise((r2) => setTimeout(r2, 1500));
    }
  }
}

// ---- SB sender with the KD-20 mitigations (b4 pattern: link + client recycle) ----
// Wire facts (witnessed, b4 lane): substrate grants fixed link_credit=1000 per
// sender link at attach, never replenishes; AMQP session incoming-window never
// advances (hard stop at 4096 transfers). Mitigation: recycle sender link every
// 400 sends, whole client every 3000.
const RECYCLE_EVERY = 400;
class ResilientSender {
  constructor(queue) {
    this.queue = queue;
    this.client = new ServiceBusClient(SB_CS, CLI_OPTS);
    this.sender = this.client.createSender(queue);
    this.linkRecycles = 0;
    this.clientRecycles = 0;
    this.clientSends = 0;
  }
  async recycleLink() {
    await closeSoon(this.sender.close());
    this.sender = this.client.createSender(this.queue);
    this.linkRecycles++;
  }
  async recycleClient() {
    await closeSoon(this.sender.close());
    await closeSoon(this.client.close());
    this.client = new ServiceBusClient(SB_CS, CLI_OPTS);
    this.sender = this.client.createSender(this.queue);
    this.clientRecycles++;
    this.clientSends = 0;
  }
  async send(msg) {
    try {
      await withTimeout(this.sender.sendMessages(msg));
    } catch (e) {
      noteErr("sb-send", e);
      await this.recycleClient();
      throw e;
    }
    if (++this.clientSends >= RECYCLE_EVERY) await this.recycleLink();
    if (this.clientSends >= 3000) await this.recycleClient();
  }
  async close() {
    await closeSoon(this.sender.close());
    await closeSoon(this.client.close());
  }
}

// Preload `n` msgs (1 KiB) to `queue`; returns {ok, ms, rate, recycles}.
async function preload(queue, n, prefix) {
  const rs = new ResilientSender(queue);
  const t0 = Date.now();
  let ok = 0, fails = 0;
  for (let i = 0; i < n; i++) {
    try {
      await rs.send({ body: crypto.randomBytes(1024), messageId: `${prefix}-${i}` });
      ok++;
    } catch {
      // retry once on a fresh client before giving up on the message
      try {
        await rs.send({ body: crypto.randomBytes(1024), messageId: `${prefix}-${i}` });
        ok++;
      } catch { fails++; }
    }
    if (ok > 0 && ok % 50 === 0) log(`  preload ${queue}: ${ok}/${n}`);
  }
  await rs.close();
  const ms = Date.now() - t0;
  return { ok, fails, ms, rate: +(ok / (ms / 1000)).toFixed(1), ...rsSummary(rs) };
}
const rsSummary = (rs) => ({ link_recycles: rs.linkRecycles, client_recycles: rs.clientRecycles });

// ---- cosmos upsert with bounded concurrency ----
async function upsertMsg(m, extra = {}) {
  const id = String(m.messageId ?? m.enqueuedSequenceNumber);
  const t0 = performance.now();
  await container.items.upsert({ id, pk: extra.pk ?? "fanin", seq: extra.seq ?? null, session: extra.session ?? null, payload: m.body });
  return performance.now() - t0;
}

// Drain loop: receive batches, upsert (bounded concurrency), complete.
// opts: {delayMs, serial, onSample}
async function drainQueue(receiver, opts = {}) {
  const { delayMs = 0, serial = false, phase = "" } = opts;
  let drained = 0, upsertErrs = 0, completeErrs = 0, recvErrs = 0, emptyPolls = 0;
  const upsertLat = [];
  const orderViolations = [];
  const sessionLastSeq = new Map();
  const depthSamples = [];
  const start = Date.now();
  let consecutiveRecvErrs = 0;
  for (;;) {
    let msgs;
    try {
      msgs = await withTimeout(receiver.receiveMessages(64, { maxWaitTimeInMs: 500 }));
      consecutiveRecvErrs = 0;
    } catch (e) {
      recvErrs++;
      noteErr(`drain-receive:${phase}`, e);
      if (++consecutiveRecvErrs > 5) break;
      await new Promise((r) => setTimeout(r, 300));
      continue;
    }
    if (!msgs.length) {
      if (++emptyPolls >= 3) break;
      continue;
    }
    emptyPolls = 0;
    drained += msgs.length;
    depthSamples.push({ t: Date.now() - start, depthAfterReceive: null, drained });
    // ordered mode (sessions): strict serial per receiver
    if (serial) {
      for (const m of msgs) {
        const sess = m.sessionId ?? "?";
        const seq = Number(m.body ?? -1);
        const last = sessionLastSeq.get(sess);
        if (last !== undefined && seq !== last + 1) orderViolations.push({ sess, last, seq });
        sessionLastSeq.set(sess, seq);
        try {
          upsertLat.push(await upsertMsg(m, { pk: `sess-${sess}`, seq, session: sess }));
        } catch (e) { upsertErrs++; noteErr(`drain-upsert:${phase}`, e); continue; }
        if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
        try { await withTimeout(receiver.completeMessage(m)); } catch (e) { completeErrs++; noteErr(`drain-complete:${phase}`, e); }
      }
    } else {
      // bounded-concurrency upsert, complete after its upsert settles
      let idx = 0;
      const worker = async () => {
        for (;;) {
          const i = idx++;
          if (i >= msgs.length) return;
          const m = msgs[i];
          try { upsertLat.push(await upsertMsg(m, { seq: i })); } catch (e) { upsertErrs++; noteErr(`drain-upsert:${phase}`, e); continue; }
          if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
          try { await withTimeout(receiver.completeMessage(m)); } catch (e) { completeErrs++; noteErr(`drain-complete:${phase}`, e); }
        }
      };
      await Promise.all(Array.from({ length: Math.min(UPSERT_CONCURRENCY, msgs.length) }, worker));
    }
  }
  const wallMs = Date.now() - start;
  const s = stats(upsertLat);
  return {
    drained, wallMs, msgsPerSec: +(drained / (wallMs / 1000)).toFixed(1),
    upsertErrs, completeErrs, recvErrs,
    upsert_p50_ms: +s.p50.toFixed(2), upsert_p95_ms: +s.p95.toFixed(2), upsert_p99_ms: +s.p99.toFixed(2),
    orderViolations: orderViolations.length, orderViolationDetail: orderViolations.slice(0, 5),
    depthSamples: depthSamples.slice(0, 12),
  };
}

// ---- phases ----
async function phasePipeline(label) {
  await ensureSubstrate();
  const queue = `c2-${label}-${Date.now()}`;
  await provisionQueue(queue);
  const pre = await preload(queue, MSGS, `c2-${label}`);
  emit({ event: "preload", phase: label, queue, tier: "sdk", target: MSGS, ...pre, errors: pre.fails });
  log(`[${label}] preload: ${pre.ok}/${MSGS} in ${pre.ms}ms = ${pre.rate}/s (tier=sdk, linkRecycles=${pre.link_recycles}, clientRecycles=${pre.client_recycles})`);
  const rxClient = new ServiceBusClient(SB_CS, CLI_OPTS);
  const receiver = rxClient.createReceiver(queue, { maxAutoLockRenewalDurationInMs: 0 });
  let r;
  try {
    r = await drainQueue(receiver, { phase: label });
  } finally {
    await closeSoon(receiver.close());
    await closeSoon(rxClient.close());
  }
  emit({ event: "result", surface: "sb->cosmos", op: `pipeline-${label}`, tier: "sdk", preload_target: MSGS, ...r, errors: r.upsertErrs + r.completeErrs + r.recvErrs });
  log(`[${label}] pipeline: drained=${r.drained} in ${r.wallMs}ms = ${r.msgsPerSec}/s upsertP50=${r.upsert_p50_ms}ms errs=${r.errors}`);
  return r;
}

// (1)
async function phase1() {
  const r = await phasePipeline("p1");
  emit({ event: "summary", phase: 1, op: "pipeline-isolated", pipeline_msgs_per_sec: r.msgsPerSec, drained: r.drained });
  return r.msgsPerSec;
}

// (2) backpressure: 50 ms artificial delay per upsert (serial worker)
async function phase2() {
  await ensureSubstrate();
  const queue = `c2-p2-${Date.now()}`;
  await provisionQueue(queue);
  const pre = await preload(queue, MSGS, "c2-p2");
  emit({ event: "preload", phase: 2, queue, tier: "sdk", target: MSGS, ...pre, errors: pre.fails });
  log(`[p2] preload: ${pre.ok}/${MSGS} in ${pre.ms}ms = ${pre.rate}/s`);
  const rxClient = new ServiceBusClient(SB_CS, CLI_OPTS);
  const receiver = rxClient.createReceiver(queue, { maxAutoLockRenewalDurationInMs: 0 });
  let r;
  try {
    r = await drainQueue(receiver, { phase: "p2", delayMs: BACKPRESSURE_DELAY_MS });
  } catch (e) {
    noteErr("p2", e);
    r = { drained: 0, wallMs: 0, msgsPerSec: 0, error: String(e?.message).slice(0, 200) };
  } finally {
    await closeSoon(receiver.close());
    await closeSoon(rxClient.close());
  }
  const expectedCap = +(1000 / BACKPRESSURE_DELAY_MS).toFixed(1);
  emit({
    event: "result", surface: "sb->cosmos", op: "pipeline-backpressure-50ms", tier: "sdk",
    preload_target: MSGS, delay_ms: BACKPRESSURE_DELAY_MS, theoretical_cap_msgs_per_sec: expectedCap,
    ...r, errors: (r.upsertErrs ?? 0) + (r.completeErrs ?? 0) + (r.recvErrs ?? 0),
  });
  log(`[p2] backpressure: drained=${r.drained} in ${r.wallMs}ms = ${r.msgsPerSec}/s (cap ${expectedCap}/s)`);
  return r;
}

// (3) session fan-in
async function phase3() {
  await ensureSubstrate();
  const queue = `c2-p3-sess-${Date.now()}`;
  await provisionQueue(queue, { requiresSession: true });
  // verify the ARM record landed
  const chk = await fetch(`${ARM_BASE}/${queue}`);
  const chkBody = await chk.json().catch(() => ({}));
  const requiresSession = chkBody?.properties?.requiresSession === true;
  emit({ event: "provision-check", phase: 3, queue, requires_session_confirmed: requiresSession, http: chk.status });

  const sendClient = new ServiceBusClient(SB_CS, CLI_OPTS);
  const sender = sendClient.createSender(queue);
  const t0 = Date.now();
  let sent = 0, sendErrs = 0;
  for (let s = 0; s < SESSIONS; s++) {
    for (let i = 0; i < SESSION_MSGS; i++) {
      try {
        await withTimeout(sender.sendMessages({ body: String(i), messageId: `s${s}-m${i}`, sessionId: `sess-${s}` }));
        sent++;
      } catch (e) {
        sendErrs++;
        noteErr("p3-send", e);
      }
    }
  }
  await closeSoon(sender.close());
  await closeSoon(sendClient.close());
  const sendMs = Date.now() - t0;
  emit({ event: "preload", phase: 3, queue, tier: "sdk", target: SESSIONS * SESSION_MSGS, ok: sent, fails: sendErrs, ms: sendMs, rate: +(sent / (sendMs / 1000)).toFixed(1) });

  // accept each session in turn; strictly ordered upserts per session
  const client = new ServiceBusClient(SB_CS, CLI_OPTS);
  let sessionsOk = 0, sessionsFailed = 0;
  const start = Date.now();
  const drainAll = { drained: 0, upsertErrs: 0, recvErrs: 0, completeErrs: 0, orderViolations: 0, upsertLat: [] };
  for (let s = 0; s < SESSIONS + 3; s++) {
    let receiver;
    try {
      receiver = await withTimeout(client.acceptNextSession(queue), 15_000);
    } catch (e) {
      noteErr("p3-acceptNextSession", e);
      sessionsFailed++;
      break;
    }
    try {
      const r = await drainQueue(receiver, { phase: "p3", serial: true });
      drainAll.drained += r.drained;
      drainAll.upsertErrs += r.upsertErrs;
      drainAll.recvErrs += r.recvErrs;
      drainAll.completeErrs += r.completeErrs;
      drainAll.orderViolations += r.orderViolations;
      if (r.drained > 0) sessionsOk++;
      emit({ event: "session", phase: 3, session: receiver.sessionId, ...r, errors: r.upsertErrs + r.recvErrs + r.completeErrs });
    } finally {
      await closeSoon(receiver.close());
    }
  }
  const wallMs = Date.now() - start;
  await closeSoon(client.close());
  const res = {
    event: "result", surface: "sb->cosmos", op: "session-fanin", tier: "sdk",
    sessions_target: SESSIONS, sessions_drained: sessionsOk, sessions_failed: sessionsFailed,
    msgs_drained: drainAll.drained, wall_ms: wallMs,
    sessions_per_sec: +(sessionsOk / (wallMs / 1000)).toFixed(2),
    msgs_per_sec: +(drainAll.drained / (wallMs / 1000)).toFixed(1),
    order_violations: drainAll.orderViolations,
    errors: drainAll.upsertErrs + drainAll.recvErrs + drainAll.completeErrs + sendErrs,
  };
  emit(res);
  log(`[p3] sessions: ${sessionsOk}/${SESSIONS} in ${wallMs}ms = ${res.sessions_per_sec}/s sessions, ${res.msgs_per_sec}/s msgs, orderViolations=${res.order_violations}`);
  return res;
}

// (4) interference: pipeline + concurrent cosmos point-reads
async function phase4(p1Rate) {
  await ensureSubstrate();
  const queue = `c2-p4-${Date.now()}`;
  await provisionQueue(queue);
  const pre = await preload(queue, MSGS, "c2-p4");
  emit({ event: "preload", phase: 4, queue, tier: "sdk", target: MSGS, ...pre, errors: pre.fails });
  const rxClient = new ServiceBusClient(SB_CS, CLI_OPTS);
  const receiver = rxClient.createReceiver(queue, { maxAutoLockRenewalDurationInMs: 0 });

  // concurrent point-read load over docs written by the pipeline itself
  let reads = 0, readErrs = 0;
  const readLat = [];
  let readersOn = true;
  const ids = [];
  const reader = (async () => {
    // seed: wait until some docs exist
    while (readersOn && reads < 5) {
      await new Promise((r) => setTimeout(r, 200));
      try { await container.items.query("SELECT * FROM c").fetchNext(); break; } catch { /* retry */ }
    }
    let i = 0;
    while (readersOn) {
      if (!ids.length) {
        try {
          const resp = await container.items.query("SELECT * FROM c").fetchNext();
          for (const d of resp.resources) ids.push([d.id, d.pk]);
        } catch (e) { readErrs++; noteErr("p4-read-seed", e); await new Promise((r) => setTimeout(r, 300)); continue; }
      }
      const [id, pk] = ids[i % Math.max(ids.length, 1)] ?? ["none", "fanin"];
      const t0 = performance.now();
      try { await container.item(id, pk).read(); } catch (e) { readErrs++; noteErr("p4-point-read", e); }
      readLat.push(performance.now() - t0);
      reads++;
      i++;
    }
  })();
  const workers = Array.from({ length: READ_CONCURRENCY - 1 }, () => reader);

  let r;
  try {
    r = await drainQueue(receiver, { phase: "p4" });
  } finally {
    readersOn = false;
    await Promise.allSettled([reader, ...workers]);
    await closeSoon(receiver.close());
    await closeSoon(rxClient.close());
  }
  const s = stats(readLat);
  const readOps = +(reads / (r.wallMs / 1000)).toFixed(1);
  emit({
    event: "result", surface: "sb->cosmos", op: "pipeline-under-read-interference", tier: "sdk",
    preload_target: MSGS, ...r, errors: r.upsertErrs + r.completeErrs + r.recvErrs,
    concurrent_reads: reads, read_ops_per_sec: readOps,
    read_p50_ms: +s.p50.toFixed(2), read_p95_ms: +s.p95.toFixed(2),
    pipeline_delta_pct: p1Rate ? +(((r.msgsPerSec - p1Rate) / p1Rate) * 100).toFixed(1) : null,
  });
  emit({
    event: "result", surface: "cosmos", op: "point-read-under-pipeline",
    n: reads, ops_per_sec: readOps, p50_ms: +s.p50.toFixed(2), p95_ms: +s.p95.toFixed(2), p99_ms: +s.p99.toFixed(2),
    errors: readErrs,
  });
  log(`[p4] interference: pipeline=${r.msgsPerSec}/s (p1 ${p1Rate}/s, delta ${(((r.msgsPerSec - p1Rate) / p1Rate) * 100).toFixed(1)}%) reads=${reads} (${readOps}/s, p50=${s.p50.toFixed(2)}ms)`);
  return r;
}

// ---- main ----
substrateChild = await bootSubstrate();
await initCosmos();
try {
  emit({
    event: "meta", sdks: [`@azure/service-bus@${SB_V}`, `@azure/cosmos@${COSMOS_V}`],
    node: process.version, ports: { arm: ARM, cosmos_egress: EGRESS, amqp: AMQP },
    msgs: MSGS, upsert_concurrency: UPSERT_CONCURRENCY, read_concurrency: READ_CONCURRENCY,
    preload_tier: "sdk (KD-20 mitigation: sender link recycle every 400 + client recycle on error; b4-witnessed fixed link_credit=1000 / session window 4096)",
    kd20_residual_note: "SB send may throttle; preload rate recorded per phase and honestly attributed to the SDK tier",
  });
  const p1 = await phase1();
  await phase2();
  await phase3();
  await phase4(p1);
} catch (e) {
  emit({ event: "fatal", name: e?.name, msg: String(e?.message ?? e).slice(0, 300) });
  console.error("FATAL", e);
  process.exitCode = 1;
} finally {
  try { await withTimeout(database.delete(), 10_000); } catch (e) { noteErr("teardown-db", e); }
  flush();
  killSubstrate(substrateChild);
  for (let i = 0; i < 20; i++) {
    if (await portFree(AMQP)) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  log("substrate down, ports free");
}
