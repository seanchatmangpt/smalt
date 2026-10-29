// FIX-4 SB topic regression leg (X3's surface) — real wire, rhea, private b88.
// ARM PUT topic+subscription, publish 2, subscribe, byte-exact FIFO.
// Run: SMALT_FIX4_NOBOOT=1 node verification/ts/fix4-topic.probe.cjs  (b88 up)
"use strict";
const path = require("node:path");
const REPO = path.resolve(__dirname, "../..");
const container = require(path.join(REPO, "verification/ts/node_modules/rhea"));
const crypto = require("node:crypto");
const fs = require("node:fs");

const marker = JSON.parse(fs.readFileSync("/tmp/smalt-substrate-state/markers/b88.boot.json", "utf8"));
const PORT = marker.ports[0], ARM_PORT = marker.ports[2], KEY = marker.shared_key;
let pass = 0, fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + (err.message || err)); }
  else { pass++; console.log("PASS " + name); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));  // SLEEP-CLASS: POLL-STEP

async function main() {
  // ARM PUT namespace/topic/subscription
  const res = await fetch("http://127.0.0.1:" + ARM_PORT + "/tenant/oauth2/v2.0/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=fix4t&client_secret=fix4t",
  });
  const tok = (await res.json()).access_token;
  const hdr = { "Authorization": "Bearer " + tok, "Content-Type": "application/json" };
  const base = "http://127.0.0.1:" + ARM_PORT + "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus";
  const ns = "fix4tns";
  let r = await fetch(base + "/namespaces/" + ns + "?api-version=2021-06-01", { method: "PUT", headers: hdr, body: JSON.stringify({ location: "eastus", sku: { name: "Standard" } }) });
  if (![200, 201, 202].includes(r.status)) throw new Error("ns PUT " + r.status);
  const TOPIC = "fix4-topic";
  r = await fetch(base + "/namespaces/" + ns + "/topics/" + TOPIC + "?api-version=2021-04-01", { method: "PUT", headers: hdr, body: JSON.stringify({ location: "eastus", properties: {} }) });
  if (![200, 201, 202].includes(probeStatus(r))) throw new Error("topic PUT " + r.status);
  r = await fetch(base + "/namespaces/" + ns + "/topics/" + TOPIC + "/subscriptions/fix4-sub?api-version=2021-04-01", { method: "PUT", headers: hdr, body: JSON.stringify({ location: "eastus", properties: {} }), });
  if (![200, 201, 202].includes(probeStatus(r))) throw new Error("sub PUT " + r.status);
  console.log("topic+subscription PUT ok");

  const conn = container.connect({ port: PORT, hostname: "127.0.0.1", container_id: "fix4-topic", reconnect: false });
  await new Promise((res) => conn.on("connection_open", res));
  // CBS authorize both addresses
  for (const entity of [TOPIC, TOPIC + "/Subscriptions/fix4-sub"]) {
    const st = await cbs(conn, "sb://127.0.0.1:" + PORT + "/" + entity);
    if (st !== 200) throw new Error("CBS " + entity + " -> " + st);
  }
  const session = conn.create_session(); session.begin();
  const tx = session.attach_sender({ target: { address: TOPIC }, name: "fix4t-tx" });
  await new Promise((res, rej) => { tx.on("sendable", res); const t = setTimeout(() => rej(new Error("tx sendable timeout")), 8000).unref(); // SLEEP-CLASS: POLL-STEP });
  tx.send({ message_id: "t1", body: "fix4-topic-payload-1" });
  tx.send({ message_id: "t2", body: "fix4-topic-payload-2" });
  session.close();

  const rxs = conn.create_session(); rxs.begin();
  const rx = rxs.attach_receiver({ source: { address: TOPIC + "/Subscriptions/fix4-sub" }, name: "fix4t-rx", credit_window: 10 });
  const got = [];
  rx.on("message", (ctx) => got.push(ctx.message.body));
  const t0 = Date.now();
  while (got.length < 2 && Date.now() - t0 < 8000) await sleep(50);  // SLEEP-CLASS: POLL-STEP
  record("topic.publish-subscribe-2-byte-exact-fifo",
    got.length === 2 && got[0] === "fix4-topic-payload-1" && got[1] === "fix4-topic-payload-2"
      ? undefined : new Error("got " + JSON.stringify(got)));
  conn.close();
  console.log("TOPIC pass=" + pass + " fail=" + fail);
  process.exit(fail ? 1 : 0);
}

function probeStatus(r) { return r.status; }
async function cbs(conn, audience) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (fn, a) => { if (!settled) { settled = true; fn(a); } };
    const session = conn.create_session(); session.begin();
    const sender = session.attach_sender({ target: { address: "$cbs" }, name: "cbs-tx-" + Date.now() });
    const receiver = session.attach_receiver({ source: { address: "$cbs" }, name: "cbs-rx-" + Date.now(), credit_window: 10 });
    receiver.on("message", (ctx) => {
      const app = ctx.message.application_properties || {};
      done(resolve, app.statusCode || app["status-code"]);
      try { session.close(); } catch (_) {}
    });
    sender.on("sendable", () => {
      const se = Math.floor(Date.now() / 1000) + 3600;
      const sr = encodeURIComponent(audience);
      const sig = crypto.createHmac("sha256", KEY).update(sr + "\n" + se).digest("base64");
      sender.send({
        message_id: "cbs-" + Date.now(), reply_to: "fix4t.reply",
        application_properties: { operation: "put-token", type: "servicebus.windows.net:sastoken", name: audience, expiration: se },
        body: "SharedAccessSignature sr=" + sr + "&sig=" + encodeURIComponent(sig) + "&se=" + se + "&skn=RootManageSharedAccessKey",
      });
    });
    const to = setTimeout(() => done(reject, new Error("cbs timeout")), 8000);  // SLEEP-CLASS: POLL-STEP (watchdog)
    to.unref();
  });
}
main().catch((e) => { console.error("TOPIC PROBE ERROR " + (e.stack || e)); process.exit(1); });
