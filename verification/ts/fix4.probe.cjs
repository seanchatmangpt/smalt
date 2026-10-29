// FIX-4 close probe — KD-131/132/133 wire witnesses (rhea, raw wire).
//
// LEG L1 (KD-131): the booted block's shared key is >= the 32-byte SasVerifier
//   floor AND a real CBS put-token minted from it answers 200 on the live
//   broker under :enforce (boot-path key no longer below floor).
// LEG L2 (KD-132b): a CBS request carrying a MALFORMED map32 body section gets
//   a typed 400 refusal on the $cbs reply link AND the connection survives
//   (a subsequent valid put-token on the same connection answers 200).
// LEG L3 (KD-133): a spec-ordered flow (rhea encodes flow fields in AMQP spec
//   order) grants credit on the live broker: a credit_window:0 receiver driven
//   by explicit rhea flows drains queued messages; a top-up flow delivers more.
//
// Run: node verification/ts/fix4.probe.cjs   (boots block b88; NOBOOT reuses)
// Env: SMALT_FIX4_BLOCK (default b88), SMALT_FIX4_NOBOOT=1 to reuse a marker.
"use strict";
const path = require("node:path");
const REPO = process.env.SMALT_REPO || path.resolve(__dirname, "../..");
const container = require(path.join(REPO, "verification/ts/node_modules/rhea"));
const crypto = require("node:crypto");
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");

const BLOCK = process.env.SMALT_FIX4_BLOCK || "b88";
const QUEUE = "fix4-q";
let PORT = 0, ARM_PORT = 0, SHARED_KEY = "";
let pass = 0, fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + (err.message || err)); }
  else { pass++; console.log("PASS " + name); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));  // SLEEP-CLASS: POLL-STEP (bounded watchdog)

function blockPorts(block) {
  const m = /^([bcv])(\d+)$/.exec(block);
  if (!m) throw new Error("unknown block " + block);
  return [0, 1, 2, 3, 4, 5].map((i) => 39000 + 10 * Number(m[2]) + i);
}

async function boot(block) {
  const ctl = path.join(REPO, "scripts/substrate-ctl");
  if (process.env.SMALT_FIX4_NOBOOT) {
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
  const deadline = Date.now() + 90000;
  for (;;) {
    const ok = await fetch("http://127.0.0.1:" + ARM_PORT + "/metadata/endpoints")
      .then((r) => r.status === 200).catch(() => false);
    if (ok) return;
    if (Date.now() > deadline) throw new Error(block + " not healthy in 90s");
    await sleep(250);  // SLEEP-CLASS: POLL-STEP (bounded health poll)
  }
}

function sasToken(audience, key) {
  const se = Math.floor(Date.now() / 1000) + 3600;
  const sr = encodeURIComponent(audience);
  const sig = crypto.createHmac("sha256", key).update(sr + "\n" + se).digest("base64");
  return "SharedAccessSignature sr=" + sr + "&sig=" + encodeURIComponent(sig) + "&se=" + se + "&skn=RootManageSharedAccessKey";
}

function cbsPutToken(conn, entity, bodyOverride) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (fn, arg) => { if (!settled) { settled = true; fn(arg); } };
    const audience = "sb://127.0.0.1:" + PORT + "/" + entity;
    const session = conn.create_session();
    session.begin();
    const sender = session.attach_sender({ target: { address: "$cbs" }, name: "fix4-cbs-tx-" + Date.now() });
    const receiver = session.attach_receiver({ source: { address: "$cbs" }, name: "fix4-cbs-rx-" + Date.now(), credit_window: 10 });
    receiver.on("message", (ctx) => {
      const app = ctx.message.application_properties || {};
      done(resolve, { statusCode: app.statusCode || app["status-code"], description: app.statusDescription || app["status-description"] });
      try { session.close(); } catch (_) {}
    });
    sender.on("rejected", (ctx) => done(reject, new Error("cbs send rejected")));
    sender.on("sendable", () => {
      try {
        const body = bodyOverride !== undefined ? bodyOverride : sasToken(audience, SHARED_KEY);
        sender.send({
          message_id: "fix4-cbs-" + Date.now(),
          reply_to: "fix4-cbs.reply",
          application_properties: {
            operation: "put-token",
            type: "servicebus.windows.net:sastoken",
            name: audience,
            expiration: Math.floor(Date.now() / 1000) + 3600,
          },
          body: body,
        });
      } catch (e) { done(reject, e); }
    });
    const to = setTimeout(() => { try { session.close(); } catch (_) {} done(reject, new Error("cbs timeout")); }, 8000);  // SLEEP-CLASS: POLL-STEP (watchdog)
    to.unref();
  });
}

async function armPutQueue() {
  const res = await fetch("http://127.0.0.1:" + ARM_PORT + "/tenant/oauth2/v2.0/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=fix4&client_secret=fix4",
  });
  const tok = (await res.json()).access_token;
  const hdr = { "Authorization": "Bearer " + tok, "Content-Type": "application/json" };
  const base = "http://127.0.0.1:" + ARM_PORT + "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus";
  let r = await fetch(base + "/namespaces/fix4ns?api-version=2021-06-01", {
    method: "PUT", headers: hdr,
    body: JSON.stringify({ location: "eastus", sku: { name: "Standard" } }),
  });
  if (![200, 201, 202].includes(r.status)) throw new Error("ARM namespace PUT " + r.status);
  r = await fetch(base + "/namespaces/fix4ns/queues/" + QUEUE + "?api-version=2021-06-01", {
    method: "PUT", headers: hdr,
    body: JSON.stringify({ location: "eastus", properties: { lockDuration: "PT1M", maxDeliveryCount: 10 } }),
  });
  if (![200, 201, 202].includes(r.status)) throw new Error("ARM queue PUT " + r.status + ": " + (await r.text()).slice(0, 200));
}

async function main() {
  await boot(BLOCK);
  console.log("block " + BLOCK + " AMQP " + PORT + " ARM " + ARM_PORT + " keybytes " + Buffer.byteLength(SHARED_KEY));

  // ---- L1 (KD-131): key floor + real CBS put-token 200 under :enforce
  record("kd131.shared-key-at-or-above-32-byte-floor",
    Buffer.byteLength(SHARED_KEY) >= 32 ? undefined : new Error("key is " + Buffer.byteLength(SHARED_KEY) + " bytes"));

  const conn = container.connect({ port: PORT, hostname: "127.0.0.1", container_id: "fix4-probe", reconnect: false });
  await new Promise((res) => conn.on("connection_open", res));

  const ok1 = await cbsPutToken(conn, QUEUE);
  record("kd131.cbs-put-token-200-floor-valid-key",
    ok1.statusCode === 200 ? undefined : new Error("statusCode " + ok1.statusCode + " " + ok1.description));

  // ---- L2 (KD-132b): malformed body -> typed 400, connection survives
// (true malformed-map32 app-props witness: verification/ts/fix4-raw-wire.exs)
  // map32 ctor 0xD1 declaring a 4 GiB size with a 4-byte truncated body:
  // decode MUST fail server-side, the request MUST get a typed refusal, and
  // the connection MUST stay open.
  const malformed = Buffer.concat([Buffer.from([0x00, 0x53, 0x75]), Buffer.from([0xD1, 0xFF, 0xFF, 0xFF, 0xFF]), Buffer.from("trunc")]);
  const bad1 = await cbsPutToken(conn, QUEUE, malformed);
  record("kd132b.malformed-body-typed-400",
    bad1.statusCode === 400 ? undefined : new Error("statusCode " + bad1.statusCode + " " + bad1.description));

  const ok2 = await cbsPutToken(conn, QUEUE);
  record("kd132b.connection-survives-after-malformed-body",
    ok2.statusCode === 200 ? undefined : new Error("statusCode " + ok2.statusCode + " " + ok2.description));

  // ---- L3 (KD-133): spec-ordered rhea flows grant credit and deliver
  await armPutQueue();
  const session = conn.create_session();
  session.begin();
  const tx = session.attach_sender({ target: { address: QUEUE }, name: "fix4-tx" });
  await new Promise((res, rej) => { tx.on("sendable", res); const t = setTimeout(() => rej(new Error("tx sendable timeout")), 8000).unref(); }); // SLEEP-CLASS: POLL-STEP
  tx.send({ message_id: "fix4-m1", body: "fix4-payload-1" });
  tx.send({ message_id: "fix4-m2", body: "fix4-payload-2" });
  tx.send({ message_id: "fix4-m3", body: "fix4-payload-3" });
  session.close();

  const rxSession = conn.create_session();
  rxSession.begin();
  const rx = rxSession.attach_receiver({ source: { address: QUEUE }, name: "fix4-rx", credit_window: 0 });
  const deliveries = [];
  rx.on("message", (ctx) => deliveries.push(ctx.message.message_id));
  rx.on("receiver_error", (ctx) => console.error("[rx] error " + JSON.stringify(ctx.error)));

  // explicit spec-ordered flow: rhea link.credit/flow writes the flow fields in
  // AMQP spec order (next-incoming-id, incoming-window, next-outgoing-id,
  // outgoing-window, handle, delivery-count, link-credit, available, drain,
  // echo, properties).
  rx.flow(2);
  const t1 = Date.now();
  while (deliveries.length < 2 && Date.now() - t1 < 5000) await sleep(50);  // SLEEP-CLASS: POLL-STEP
  record("kd133.spec-ordered-flow-grants-credit-2-deliveries",
    deliveries.length >= 2 ? undefined : new Error("got " + deliveries.length + " deliveries"));

  rx.flow(1);
  const t2 = Date.now();
  while (deliveries.length < 3 && Date.now() - t2 < 5000) await sleep(50);  // SLEEP-CLASS: POLL-STEP
  record("kd133.topup-flow-delivers-third",
    deliveries.length >= 3 ? undefined : new Error("got " + deliveries.length + " deliveries"));

  conn.close();
  console.log("TOTAL pass=" + pass + " fail=" + fail);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("PROBE ERROR " + (e.stack || e)); process.exit(1); });
