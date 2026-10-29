"use strict";
// KD-127 falsifier (raw rhea wire).
// PT2S queue via ARM, one message, receiver rx takes a delivery (unsettled),
// hold past expiry WITH rx attached; then (a) a reflow on rx and (b) a second
// link rx2 must each see redelivery. Pre-fix: no transfer ever arrives while
// rx lives; only rx's link close restores re-claimability (K6 witness).
//
// Run: node verification/ts/kd127.probe.cjs
// Env: SMALT_KD127_BLOCK (default b21), SMALT_KD127_NOBOOT=1 to use an
// already-running block (ports/key read from its marker).
"use strict";
const path = require("node:path");
const REPO = process.env.SMALT_REPO || path.resolve(__dirname, "../..");
const container = require(path.join(REPO, "verification/ts/node_modules/rhea"));
const crypto = require("node:crypto");
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");

const BLOCK = process.env.SMALT_KD127_BLOCK || "b21";
const QUEUE = "kd127-q";
let PORT = 0, ARM_PORT = 0, SHARED_KEY = "";
let pass = 0, fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + err.message); }
  else { pass++; console.log("PASS " + name); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)

function blockPorts(block) {
  const m = /^([bcv])(\d+)$/.exec(block);
  if (!m) throw new Error("unknown block " + block);
  const base = m[1] === "b" ? 39000 : m[1] === "c" ? 39000 : 39000; // b/c/v all 39000+10N
  return [0, 1, 2, 3, 4, 5].map((i) => base + 10 * Number(m[2]) + i);
}

async function boot(block) {
  const ctl = path.join(REPO, "scripts/substrate-ctl");
  if (process.env.SMALT_KD127_NOBOOT) {
    const marker = JSON.parse(fs.readFileSync("/tmp/smalt-substrate-state/markers/" + block + ".boot.json", "utf8"));
    PORT = marker.ports[0];
    ARM_PORT = marker.ports[2];
    SHARED_KEY = marker.shared_key;
    return;
  }
  spawnSync(ctl, ["down", "--block", block, "--mode", "sweep"], { timeout: 60000 });
  const res = spawnSync(ctl, ["up", "--block", block, "--fresh"], { timeout: 180000, encoding: "utf8" });
  if (res.status !== 0) {
    console.error(res.stdout);
    console.error(res.stderr);
    process.exit(3);
  }
  const marker = JSON.parse(fs.readFileSync("/tmp/smalt-substrate-state/markers/" + block + ".boot.json", "utf8"));
  PORT = marker.ports[0];
  ARM_PORT = marker.ports[2];
  SHARED_KEY = marker.shared_key;
  // bounded poll for ARM health (SLEEP-CLASS: POLL-STEP)
  const deadline = Date.now() + 90000;
  for (;;) {
    const ok = await fetch("http://127.0.0.1:" + ARM_PORT + "/metadata/endpoints")
      .then((r) => r.status === 200).catch(() => false);
    if (ok) return;
    if (Date.now() > deadline) throw new Error(block + " not healthy in 90s");
    await sleep(250);  // SLEEP-CLASS: POLL-STEP (bounded redelivery/lock-expiry observation window — the quantity under test)
  }
}

async function armPutPt2sQueue() {
  // STS token + ARM PUT queue with camelCase lockDuration PT2S (K6 KD-50 shape)
  const res = await fetch("http://127.0.0.1:" + ARM_PORT + "/tenant/oauth2/v2.0/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=kd127&client_secret=kd127",
  });
  const tok = (await res.json()).access_token;
  const hdr = { "Authorization": "Bearer " + tok, "Content-Type": "application/json" };
  const base = "http://127.0.0.1:" + ARM_PORT + "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus";
  let r = await fetch(base + "/namespaces/kd127ns?api-version=2021-06-01", {
    method: "PUT", headers: hdr,
    body: JSON.stringify({ location: "eastus", sku: { name: "Standard" } }),
  });
  if (![200, 201, 202].includes(r.status)) throw new Error("ARM namespace PUT " + r.status);
  r = await fetch(base + "/namespaces/kd127ns/queues/" + QUEUE + "?api-version=2021-06-01", {
    method: "PUT", headers: hdr,
    body: JSON.stringify({ location: "eastus", properties: { lockDuration: "PT2S", maxDeliveryCount: 10 } }),
  });
  if (![200, 201, 202].includes(r.status)) throw new Error("ARM queue PUT " + r.status + ": " + (await r.text()).slice(0, 200));
}

function sasToken(audience, key) {
  const se = Math.floor(Date.now() / 1000) + 3600;
  const sr = encodeURIComponent(audience);
  const sig = crypto.createHmac("sha256", key).update(sr + "\n" + se).digest("base64");
  return "SharedAccessSignature sr=" + sr + "&sig=" + encodeURIComponent(sig) + "&se=" + se + "&skn=RootManageSharedAccessKey";
}

function cbsAuthorize(conn, entity) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (fn, arg) => { if (!settled) { settled = true; fn(arg); } };
    const audience = "sb://127.0.0.1:" + PORT + "/" + entity;
    const session = conn.create_session();
    session.begin();
    const sender = session.attach_sender({ target: { address: "$cbs" }, name: "kd127-cbs-tx" });
    const receiver = session.attach_receiver({ source: { address: "$cbs" }, name: "kd127-cbs-rx", credit_window: 10 });
    receiver.on("message", (ctx) => {
      const app = ctx.message.application_properties || {};
      done(resolve, { statusCode: app.statusCode || app["status-code"], description: app.statusDescription || app["status-description"] });
    });
    sender.on("sendable", () => {
      try {
        sender.send({
          message_id: "kd127-cbs-" + Date.now(),
          reply_to: "kd127-cbs.reply",
          application_properties: {
            operation: "put-token",
            type: "servicebus.windows.net:sastoken",
            name: audience,
            expiration: Math.floor(Date.now() / 1000) + 3600,
          },
          body: sasToken(audience, SHARED_KEY),
        });
      } catch (e) { done(reject, e); }
    });
    const to = setTimeout(() => done(reject, new Error("cbs timeout")), 8000);  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
    to.unref();
  });
}

function safeErr(e) {
  try {
    const c = e && e.error && e.error.condition ? String(e.error.condition) : "";
    const d = e && e.error && e.error.description ? String(e.error.description) : "";
    return (c + " " + d).trim() || JSON.stringify(e && e.error ? e.error : e).slice(0, 200);
  } catch (_) { return "unprintable"; }
}

// open a queue receiver on its own session; returns {rx, session, deliveries}
function openReceiver(conn, name) {
  const session = conn.create_session();
  session.begin();
  const rx = session.attach_receiver({ source: { address: QUEUE }, name, autoaccept: false, credit_window: 0 });
  const deliveries = [];
  rx.on("message", (ctx) => {
    deliveries.push({
      id: ctx.message.message_id,
      dc: ctx.message.header && ctx.message.header.delivery_count,
      tag: ctx.delivery && ctx.delivery.tag && Buffer.from(ctx.delivery.tag).toString("hex"),
    });
  });
  rx.on("receiver_error", (ctx) => console.error("[" + name + "] receiver_error " + safeErr(ctx.error)));
  return { rx, session, deliveries, name };
}

function sendOne(conn) {
  return new Promise((resolve, reject) => {
    const session = conn.create_session();
    session.begin();
    const tx = session.attach_sender({ target: { address: QUEUE }, name: "kd127-tx-" + Date.now() });
    tx.on("sendable", () => {
      try {
        tx.send({ message_id: "kd127-m1", body: "kd127-payload" });
        session.close();
        resolve();
      } catch (e) { reject(e); }
    });
    const to = setTimeout(() => reject(new Error("sendable timeout")), 8000);  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
    to.unref();
  });
}

let conn;

async function main() {
  await boot(BLOCK);
  await armPutPt2sQueue();
  console.log("block " + BLOCK + " AMQP " + PORT + " ARM " + ARM_PORT + "; PT2S queue " + QUEUE);

  conn = container.connect({ host: "127.0.0.1", port: PORT, reconnect: false });
  await new Promise((res, rej) => {
    conn.once("connection_open", res);
    conn.once("connection_error", (e) => rej(new Error("connection_error " + safeErr(e))));
    const t = setTimeout(() => rej(new Error("connect timeout")), 8000);  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
    t.unref();
  });
  const cbs = await cbsAuthorize(conn, QUEUE);
  if (cbs.statusCode !== 200) throw new Error("CBS auth failed " + cbs.statusCode + " " + cbs.description);
  console.log("CBS put-token OK");

  await sendOne(conn);

  // rx takes delivery 1, never settles, no further credit (pure streaming
  // receiver: credit_window 1000 keeps credit outstanding WITHOUT any client
  // reflow after the drain top-up — the sweep is the only redelivery path)
  const rx = openReceiver(conn, "kd127-rx");
  rx.rx.add_credit(1);
  const t0 = Date.now();
  while (rx.deliveries.length === 0 && Date.now() - t0 < 5000) await sleep(50);  // SLEEP-CLASS: POLL-STEP (bounded observable poll — the redelivery quantity under test)
  if (rx.deliveries.length !== 1) throw new Error("no first delivery to rx");
  console.log("first delivery to rx: " + JSON.stringify(rx.deliveries[0]));

  // hold past PT2S expiry WITH rx attached (no settlement, no credit on rx)
  await sleep(2600);  // SLEEP-CLASS: POLL-STEP (bounded redelivery/lock-expiry observation window — the quantity under test)

  // leg A: reflow on the SAME attached rx — must redeliver (deliveryCount 2)
  rx.rx.add_credit(1);
  const ta = Date.now();
  while (rx.deliveries.length < 2 && Date.now() - ta < 5000) await sleep(50);  // SLEEP-CLASS: POLL-STEP (bounded observable poll — the redelivery quantity under test)
  const a = rx.deliveries[1];
  if (!a) {
    record("KD-127 leg A redelivery on attached rx after PT2S expiry", new Error("no transfer within 5s"));
  } else if (a.dc != null && a.dc !== 2) {
    record("KD-127 leg A redelivery on attached rx", new Error("deliveryCount " + a.dc + " != 2"));
  } else {
    record("KD-127 leg A redelivery on attached rx" + (a.dc != null ? " (dc=" + a.dc + ")" : " (no header dc)"), null);
  }

  // leg B: a FRESH link rx2 while rx still attached — must redeliver
  const rx2 = openReceiver(conn, "kd127-rx2");
  rx2.rx.add_credit(1);
  const tb = Date.now();
  while (rx2.deliveries.length === 0 && Date.now() - tb < 5000) await sleep(50);  // SLEEP-CLASS: POLL-STEP (bounded observable poll — the redelivery quantity under test)
  const b = rx2.deliveries[0];
  if (!b) {
    record("KD-127 leg B redelivery on fresh rx2 while rx attached", new Error("no transfer within 5s"));
  } else {
    record("KD-127 leg B redelivery on fresh rx2 while rx attached (dc=" + b.dc + ")", null);
  }

  try { conn.close(); } catch (_) {}
  console.log("KD127 SUMMARY pass=" + pass + " fail=" + fail);
  process.exitCode = fail === 0 ? 0 : 1;
}

main().catch((e) => { console.error("harness:", e.message || e); try { conn && conn.close(); } catch (_) {} process.exit(1); });
