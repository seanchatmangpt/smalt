// W13-B witness probe (KD-73 get-message-sessions, KD-74 batch-delete-messages)
// rhea 3.0.5 raw $management over SASL ANONYMOUS + CBS SAS put-token.
// Successor of K6's deadlocked raw probe (tmp/k6_mgmt.cjs). Boots its OWN
// lane-block substrate (b13, ports 39130..39135) via substrate-ctl with a
// per-boot key — never touches or restarts the main substrate or another
// lane's block — provisions a requiresSession queue via ARM, then witnesses
// the two ops over the real wire.
//
// Run: node verification/ts/kd73-74.probe.cjs
"use strict";
const path = require("node:path");
const REPO = process.env.SMALT_REPO || path.resolve(__dirname, "../..");
const container = require(path.join(REPO, "verification/ts/node_modules/rhea"));
const { createRequire } = require("node:module");
const azsb = createRequire(path.join(REPO, "verification/ts/package.json"))("@azure/service-bus");
const crypto = require("node:crypto");
const fs = require("node:fs");
const net = require("node:net");
const { spawnSync } = require("node:child_process");

const CERT_DIR = path.join(REPO, ".smalt/tls");
const BLOCK = process.env.SMALT_KD73_BLOCK || "b13"; // lane b13 -> ports 39130..39135
const QUEUE = "kd73-sess-q"; // requiresSession queue, ARM-provisioned

let PORT = 0;
let ARM_PORT = 0;
let SHARED_KEY = "";

let pass = 0, fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + err.message); }
  else { pass++; console.log("PASS " + name); }
}
// ---- substrate boot via substrate-ctl (lane block lease) --------------------
async function bootPrivate(block) {
  const ctlPath = path.join(REPO, "scripts/substrate-ctl");
  const m = /^b(\d+)$/.exec(block);
  if (!m) throw new Error("unknown block " + block);
  const ports = [0, 1, 2, 3, 4, 5].map((i) => 39000 + 10 * Number(m[1]) + i);
  PORT = ports[0];
  ARM_PORT = ports[2];

  spawnSync(ctlPath, ["down", "--block", "--mode", "sweep"], { timeout: 60000 });
  const res = spawnSync(ctlPath, ["up", "--block", block, "--fresh"], { timeout: 120000, encoding: "utf8" });
  if (res.status !== 0) {
    console.error(res.stdout);
    console.error(res.stderr);
    process.exit(3);
  }
  SHARED_KEY = fs.readFileSync("/tmp/smalt-substrate-state/keys/" + block + ".sbkey", "utf8").trim();
  // bounded poll for ARM health (SLEEP-CLASS: POLL-STEP)
  const deadline = Date.now() + 90000;
  for (;;) {
    const ok = await fetch("http://127.0.0.1:" + ARM_PORT + "/metadata/endpoints").then((r) => r.status === 200).catch(() => false);
    if (ok) return ports;
    if (Date.now() > deadline) throw new Error(block + " not healthy in 90s");
    await new Promise((r) => setTimeout(r, 250));  // SLEEP-CLASS: POLL-STEP (bounded request timeout — hard deadline, not coordination)
  }
}

function downBlock(block) {
  const ctlPath = path.join(REPO, "scripts/substrate-ctl");
  const res = spawnSync(ctlPath, ["down", "--block", block, "--mode", "sweep"], { timeout: 60000 });
  if (res.status !== 0) console.error("[kd73-74] down exit=" + res.status);
}

// ---- AMQP helpers -----------------------------------------------------------

function safeErr(e) {
  try {
    const c = e && e.error && e.error.condition ? String(e.error.condition) : "";
    const d = e && e.error && e.error.description ? String(e.error.description) : "";
    if (c || d) return (c + " " + d).trim();
    return JSON.stringify(e && e.error ? e.error : e).slice(0, 200);
  } catch (_) { return "unprintable"; }
}

// Build a SharedAccessSignature for an audience string.
function sasToken(audience, key) {
  const se = Math.floor(Date.now() / 1000) + 3600;
  const sr = encodeURIComponent(audience);
  const sig = crypto.createHmac("sha256", key).update(sr + "\n" + se).digest("base64");
  return "SharedAccessSignature sr=" + sr + "&sig=" + encodeURIComponent(sig) + "&se=" + se + "&skn=RootManageSharedAccessKey";
}

// CBS put-token for one entity (audience = sb://host:port/entity).
function cbsAuthorize(conn, entity) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (fn, arg) => { if (!settled) { settled = true; fn(arg); } };
    const audience = "sb://127.0.0.1:" + PORT + "/" + entity;
    const session = conn.create_session();
    session.begin();
    const sender = session.attach_sender({ target: { address: "$cbs" }, name: "kd-cbs-tx" });
    const receiver = session.attach_receiver({ source: { address: "$cbs" }, name: "kd-cbs-rx", credit_window: 10 });
    const msgId = "kd-cbs-" + entity + "-" + Date.now();
    const req = {
      message_id: msgId,
      reply_to: "kd-cbs.reply-" + entity,
      application_properties: {
        operation: "put-token",
        type: "servicebus.windows.net:sastoken",
        name: audience,
        expiration: Math.floor(Date.now() / 1000) + 3600,
      },
      body: sasToken(audience, SHARED_KEY), // SDK form: token string IS the body
    };
    receiver.on("message", (ctx) => {
      const app = ctx.message.application_properties || {};
      done(resolve, { statusCode: app.statusCode || app["status-code"], description: app.statusDescription || app["status-description"] });
    });
    sender.on("sendable", () => { try { sender.send(req); } catch (e) { done(reject, e); } });
    const to = setTimeout(() => done(reject, new Error("cbs timeout")), 8000);  // SLEEP-CLASS: POLL-STEP (bounded request timeout — hard deadline, not coordination)
  });
}

// Persistent $management links on one session; per-op requests correlated by
// message-id via message PROPERTIES correlation-id (server reply shape).
let MGMT = null;
function openMgmt(conn) {
  const session = conn.create_session();
  session.begin();
  // SDK-canonical per-entity management node: <entity>/$management — the
  // server resolves queue_from_request from the receiving mgmt link address.
  const sender = session.attach_sender({ target: { address: QUEUE + "/$management" }, name: "kd-mgmt-tx" });
  const receiver = session.attach_receiver({ source: { address: QUEUE + "/$management" }, name: "kd-mgmt-rx", credit_window: 100 });
  const waiters = new Map();
  receiver.on("message", (ctx) => {
    const m = ctx.message;
    const app = m.application_properties || {};
    const corr = m.correlation_id !== undefined ? m.correlation_id : app.correlation_id;
    const w = waiters.get(String(corr));
    if (!w) return; // unsolicited; ignore
    waiters.delete(String(corr));
    w({
      statusCode: app.statusCode || app["status-code"],
      description: app.statusDescription || app["status-description"],
      body: m.body,
    });
  });
  return {
    call: function (op, body) {
      return new Promise((resolve, reject) => {
        const msgId = "kd73-74-" + op + "-" + Date.now() + "-" + Math.random().toString(36).slice(2);
        waiters.set(String(msgId), resolve);
        const to = setTimeout(() => {  // SLEEP-CLASS: POLL-STEP (bounded request timeout — hard deadline, not coordination)
          waiters.delete(String(msgId));
          reject(new Error("mgmt timeout: " + op));
        }, 8000);
        const req = {
          message_id: msgId,
          reply_to: "$management",
          application_properties: {
            operation: "com.microsoft:" + op,
            "com.microsoft:server-timeout": 5000,
          },
          body: body,
        };
        const trySend = () => {
          try { sender.send(req); } catch (e) { /* wait for sendable */ }
        };
        if (sender.sendable()) trySend();
        else sender.once("sendable", trySend);
      });
    },
  };
}

// Lock the session once via the real SDK (acceptNextSession + receive +
// settle). Acquiring the session lock creates the :smalt_sb_sessions record
// that get-message-sessions / set-session-state read. The SDK's attach uses
// the symbol-keyed session-filter shape the server parses; rhea's plain-map
// filter form wedges the server connection (witnessed separately).
async function sdkLockSession(client) {
  const rx = await client.acceptNextSession(QUEUE, { maxWaitTimeInMs: 6000 });
  const msgs = await rx.receiveMessages(1, { maxWaitTimeInMs: 4000 });
  if (msgs.length === 0) throw new Error("no delivery on accepted session");
  await rx.completeMessage(msgs[0]);
  return rx; // keep the receiver open so the lock stays ours
}
// ARM: STS token + namespace + requiresSession queue on the private ARM port.
async function armProvision() {
  const res = await fetch("http://127.0.0.1:" + ARM_PORT + "/tenant/oauth2/v2.0/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=kd73&client_secret=kd73",
  });
  const tok = (await res.json()).access_token;
  const hdr = { "Authorization": "Bearer " + tok, "Content-Type": "application/json" };
  const base = "http://127.0.0.1:" + ARM_PORT + "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus";
  let r = await fetch(base + "/namespaces/kd73ns?api-version=2021-06-01", {
    method: "PUT", headers: hdr,
    body: JSON.stringify({ location: "eastus", sku: { name: "Standard" } }),
  });
  if (![200, 201, 202].includes(r.status)) throw new Error("ARM namespace PUT " + r.status);
  r = await fetch(base + "/namespaces/kd73ns/queues/" + QUEUE + "?api-version=2021-06-01", {
    method: "PUT", headers: hdr,
    body: JSON.stringify({ location: "eastus", properties: { requiresSession: true, lockDuration: "PT5M" } }),
  });
  const body = await r.json();
  if (![200, 201, 202].includes(r.status)) throw new Error("ARM queue PUT " + r.status);
  if (!body.properties || body.properties.requiresSession !== true) {
    throw new Error("queue not requiresSession: " + JSON.stringify(body.properties));
  }
}

async function main() {
  await bootPrivate(BLOCK);
  await armProvision();
  console.log("booted " + BLOCK + " (AMQP " + PORT + ", ARM " + ARM_PORT + "); queue " + QUEUE + " requiresSession=true");

  const conn = container.connect({ host: "127.0.0.1", port: PORT, reconnect: false }); // typed failures; CBS claims are per-connection, so silent auto-replay would zombie
  conn.on("disconnected", () => console.error("[conn] disconnected"));
  await new Promise((res, rej) => {
    conn.once("connection_open", res);
    conn.once("connection_error", (e) => rej(new Error("connection_error " + safeErr(e))));
    const t = setTimeout(() => rej(new Error("connect timeout")), 8000);  // SLEEP-CLASS: POLL-STEP (bounded request timeout — hard deadline, not coordination)
    t.unref();
  });
  const cbs = await cbsAuthorize(conn, QUEUE);
  if (cbs.statusCode !== 200) {
    console.error("CBS auth failed: " + cbs.statusCode + " " + cbs.description);
    conn.close();
    downBlock(BLOCK);
    process.exit(2);
  }
  console.log("CBS put-token OK (audience sb://127.0.0.1:" + PORT + "/" + QUEUE + ")");
  MGMT = openMgmt(conn);
  const csStr = "Endpoint=sb://127.0.0.1:" + PORT + ";SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=" + SHARED_KEY + ";UseDevelopmentEmulator=true";
  const client = new azsb.ServiceBusClient(csStr, { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } });

  // ---- KD-73: seed 3 session messages, lock session, list sessions --------
  try {
    const sdkSender = client.createSender(QUEUE);
    for (const b of ["kd73-a", "kd73-b", "kd73-c"]) {
      await sdkSender.sendMessages([{ body: b, messageId: b, sessionId: "w13s1" }]);
    }
    await sdkSender.close();
    const sessRx = await sdkLockSession(client);
    console.log("session w13s1 locked via SDK acceptNextSession");
    const r = await MGMT.call("get-message-sessions", { queue: QUEUE });
    if (r.statusCode !== 200) throw new Error("statusCode=" + r.statusCode + " " + r.description);
    const b = r.body || {};
    const ids = b["sessions-ids"];
    if (!Array.isArray(ids)) throw new Error("sessions-ids not array: " + JSON.stringify(b).slice(0, 200));
    if (!Array.isArray(b.sessions)) throw new Error("sessions detail not array");
    if (b.sessions.length !== ids.length) throw new Error("detail length mismatch");
    if (typeof b.skip !== "number") throw new Error("skip not number: " + b.skip);
    if (!ids.includes("w13s1")) throw new Error("seeded session w13s1 not listed: " + JSON.stringify(ids));
    const d = b.sessions.find((x) => x && x["session-id"] === "w13s1");
    if (!d) throw new Error("no detail entry for w13s1");
    for (const k of ["session-state-size", "message-count", "updated-at"]) {
      if (!(k in d)) throw new Error("detail missing " + k + ": " + JSON.stringify(d));
    }
    record("KD-73 get-message-sessions shape (sessions-ids + detail + skip)", null);
  } catch (e) {
    record("KD-73 get-message-sessions shape", e);
  }

  // ---- KD-73 support: set/get session state over management ---------------
  try {
    const st = Buffer.from("kd73-state-v1");
    const set = await MGMT.call("set-session-state", {
      queue: QUEUE, "session-id": "w13s1", "session-state": st,
    });
    if (set.statusCode !== 200) throw new Error("set statusCode=" + set.statusCode + " " + set.description);
    const get = await MGMT.call("get-session-state", { queue: QUEUE, "session-id": "w13s1" });
    if (get.statusCode !== 200) throw new Error("get statusCode=" + get.statusCode);
    const got = get.body && get.body["session-state"];
    if (!got || Buffer.from(got).toString() !== "kd73-state-v1") {
      throw new Error("state mismatch: " + JSON.stringify(get.body).slice(0, 120));
    }
    record("KD-73 set/get-session-state round trip", null);
  } catch (e) {
    record("KD-73 set/get-session-state round trip", e);
  }

  // ---- KD-74: peek -> batch-delete by real sequence numbers ---------------
  try {
    const peek = await MGMT.call("peek-message", {
      queue: QUEUE, "from-sequence-number": 0, "message-count": 10,
    });
    if (peek.statusCode !== 200) throw new Error("peek statusCode=" + peek.statusCode);
    const msgs = (peek.body || {}).messages || [];
    if (msgs.length !== 2) throw new Error("expected 2 remaining messages, peek gave " + msgs.length);
    const seqs = msgs.map((m) => m["sequence-number"]);
    if (seqs.some((s) => typeof s !== "number")) {
      throw new Error("sequence-number not number: " + JSON.stringify(seqs));
    }
    const del = await MGMT.call("batch-delete-messages", { queue: QUEUE, "sequence-numbers": seqs });
    if (del.statusCode !== 200) throw new Error("delete statusCode=" + del.statusCode + " " + del.description);
    const peek2 = await MGMT.call("peek-message", {
      queue: QUEUE, "from-sequence-number": 0, 
      "message-count": 10,
    });
    const after = (peek2.body || {}).messages || [];
    if (after.length !== 0) throw new Error("not empty after delete: " + after.length + " left");
    record("KD-74 batch-delete on real sequence numbers (peek -> delete -> empty re-peek)", null);

    const del2 = await MGMT.call("batch-delete-messages", { queue: QUEUE, "sequence-numbers": [999999] });
    if (del2.statusCode !== 200) throw new Error("absent-seq statusCode=" + del2.statusCode);
    record("KD-74 absent-sequence-number skip (delete-present semantics)", null);
  } catch (e) {
    record("KD-74 batch-delete on real sequence numbers", e);
  }

  // ---- negatives -----------------------------------------------------------
  try {
    const r = await MGMT.call("get-message-sessions", { queue: "kd73-no-such-queue" });
    // emulator law (witnessed): unknown queue lists EMPTY 200 — QUEUE_REQUIRED
    // fires only on a blank queue field, NOT_FOUND is not part of this op
    if (r.statusCode !== 200) throw new Error("expected 200, got " + r.statusCode);
    const ids = (r.body || {})["sessions-ids"];
    if (!Array.isArray(ids) || ids.length !== 0) throw new Error("expected empty sessions-ids, got " + JSON.stringify(r.body));
    record("KD-73 negative: unknown queue -> 200 empty sessions (emulator law)", null);
  } catch (e) { record("KD-73 negative unknown queue", e); }

  try {
    const r = await MGMT.call("get-session-state", { queue: QUEUE, "session-id": "kd73-no-such-session" });
    if (r.statusCode !== 404) throw new Error("expected 404, got " + r.statusCode);
    if (r.description !== "SESSION_NOT_FOUND") throw new Error("description=" + r.description);
    record("KD-73 negative: unknown session -> 404 SESSION_NOT_FOUND", null);
  } catch (e) { record("KD-73 negative unknown session", e); }

  try {
    const r = await MGMT.call("batch-delete-messages", { queue: QUEUE });
    if (r.statusCode !== 400) throw new Error("missing seqs expected 400, got " + r.statusCode);
    if (r.description !== "SEQUENCE_NUMBERS_REQUIRED") throw new Error("description=" + r.description);
    record("KD-74 negative: missing sequence numbers -> 400 SEQUENCE_NUMBERS_REQUIRED", null);
  } catch (e) { record("KD-74 negative missing sequence numbers", e); }

  try {
    const r = await MGMT.call("definitely-not-an-op", {});
    if (r.statusCode !== 501) throw new Error("expected 501, got " + r.statusCode);
    record("negative: unknown operation -> 501 UNSUPPORTED_OPERATION", null);
  } catch (e) { record("negative unknown op", e); }

  conn.close();
  try { await client.close(); } catch (e) {}
  console.log("KD73-74 SUMMARY pass=" + pass + " fail=" + fail);
  process.exitCode = fail === 0 ? 0 : 1;
  downBlock(BLOCK);
}

// Hard top-level watchdog (sb-extra lesson: attach can hang past timeouts).
const WATCHDOG_MS = parseInt(process.env.SMALT_KD73_WATCHDOG_MS || "180000", 10);
// SLEEP-CLASS: SCHEDULING (hard top-level watchdog, typed exit 3)
const watchdog = setTimeout(function () {  // SLEEP-CLASS: POLL-STEP (bounded request timeout — hard deadline, not coordination)
  console.error("[kd73-74] WATCHDOG: no verdict in " + WATCHDOG_MS + "ms — typed fail");
  downBlock(BLOCK);
  process.exit(3);
}, WATCHDOG_MS);
watchdog.unref();

main().catch((e) => {
  console.error("harness:", e);
  downBlock(BLOCK);
  process.exit(1);
});
