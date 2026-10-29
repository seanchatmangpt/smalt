// BK-65 cross-plane interop witness, shared substrate block b65.
//   node verification/ts/bk65.probe.cjs   (exit 0 pass / 1 fail)
"use strict";
const { createRequire } = require("node:module");
const path = require("node:path");
const crypto = require("node:crypto");
const net = require("node:net");
const fs = require("node:fs");

const REPO = path.resolve(__dirname, "../..");
const rhea = createRequire(path.join(REPO, "verification/ts/package.json"))("rhea");
const container = rhea.create_container();
container.on("error", function (e) { console.log("[dbg] container error: " + e.message); });

const AMQP_PORT = Number(process.env.BK65_AMQP_PORT || 39650);
const ARM_PORT = Number(process.env.BK65_ARM_PORT || 39652);
const SHARED_KEY = fs.readFileSync("/tmp/smalt-substrate-state/keys/b65.sbkey", "utf8").trim();
const RG = "bk65-rg";
const NS = "bk65-ns";
const Q1 = "q1";
const Q2 = "q2-never-created";
const PAYLOAD = "bk65-exact-" + crypto.randomBytes(8).toString("hex");

function mintToken(audience, key, ttlSec) {
  const se = Math.floor(Date.now() / 1000) + (ttlSec || 600);
  const sr = encodeURIComponent(audience);
  const sig = crypto.createHmac("sha256", key).update(sr + "\n" + se).digest("base64");
  return "SharedAccessSignature sr=" + sr + "&sig=" + encodeURIComponent(sig) +
    "&se=" + se + "&skn=RootManageSharedAccessKey";
}

function putToken(conn, audience) {
  return new Promise(function (resolve, reject) {
    const sender = conn.open_sender("$cbs");
    sender.once("sendable", function () {
      const replyTo = "cbs-reply-" + crypto.randomBytes(4).toString("hex");
      const rx = conn.open_receiver({ name: replyTo, target: { address: replyTo } });
      rx.once("receiver_open", function () {
        rx.add_credit(1);
        sender.send({
          properties: { message_id: "cbs-" + Date.now(), subject: "put-token", to: audience, reply_to: replyTo },
          application_properties: {
            operation: "put-token", type: "servicebus.windows.net:sastoken",
            name: audience, "reply-to": replyTo
          },
          body: mintToken(audience, SHARED_KEY)
        });
        rx.on("message", function (c) {
          const status = c.message.application_properties["status-code"];
          sender.close(); rx.close();
          status === 200 ? resolve(status) : reject(new Error("put-token " + status));
        });
      });
    });
    // SLEEP-CLASS: POLL-STEP — deadline guard bounding the put-token event wait; typed failure on expiry.
    setTimeout(function () { reject(new Error("put-token timeout")); }, 8000);
  });
}

function conn0() {
  const c = container.connect({ host: "127.0.0.1", port: AMQP_PORT, username: "anonymous", reconnect: false });
  c.on("connection_error", function (e) { console.log("[dbg] conn-error", e.error && e.error.condition); });
  return c;
}

async function armMintBearer(armPort) {
  const res = await fetch("http://127.0.0.1:" + armPort + "/dev/oauth2/v2.0/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials", client_id: "bk65-probe",
      client_secret: "bk65", scope: "https://management.azure.com/.default"
    }).toString()
  });
  if (!res.ok) throw new Error("STS " + res.status);
  const j = await res.json();
  return j.access_token;
}

async function armDelete(armPort, token, path) {
  const res = await fetch("http://127.0.0.1:" + armPort +
    "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/" + RG +
    "/providers/Microsoft.ServiceBus/namespaces/" + NS + path + "?api-version=2021-04-01", {
    method: "DELETE", headers: { authorization: "Bearer " + token }
  });
  return res.status;
}

async function armPut(armPort, token, path, body) {
  const res = await fetch("http://127.0.0.1:" + armPort +
    "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/" + RG +
    "/providers/Microsoft.ServiceBus/namespaces/" + NS + path + "?api-version=2021-04-01", {
    method: "PUT",
    headers: { authorization: "Bearer " + token, "content-type": "application/json" },
    body: JSON.stringify(body)
  });
  return res.status;
}

// Send one message; resolves {accepted} or {accepted:false, condition, description}.
function sendLeg(conn, q) {
  return new Promise(async function (resolve, reject) {
    try { await putToken(conn, "sb://127.0.0.1:" + AMQP_PORT + "/" + q); } catch (e) { return reject(e); }
    const tx = conn.open_sender(q);
    let done = false;
    const finish = function (r) { if (!done) { done = true; r.tx = tx; resolve(r); } };
    const readErr = function (ctx) { return (ctx && ctx.error) || tx.error || null; };
    tx.once("sender_error", function (ctx) { const e = readErr(ctx); finish({ accepted: false, condition: e && e.condition, description: e && e.description }); });
    tx.once("sender_close", function (ctx) { const e = readErr(ctx); finish({ accepted: false, condition: e && e.condition, description: e && e.description }); });
    tx.once("sendable", function () {
      tx.once("accepted", function () { finish({ accepted: true }); });
      tx.send({ body: PAYLOAD, message_id: "bk65-" + Date.now() });
    });
    // SLEEP-CLASS: POLL-STEP — deadline guard bounding the send-acceptance event wait; typed failure on expiry.
    setTimeout(function () { finish({ accepted: false, condition: "timeout" }); }, 10000);
  });
}

// Receive one message, settle accepted (complete), resolve {body, deliveryId}.
function receiveLeg(conn, q) {
  return new Promise(async function (resolve, reject) {
    try { await putToken(conn, "sb://127.0.0.1:" + AMQP_PORT + "/" + q); } catch (e) { return reject(e); }
    const rx = conn.open_receiver({ name: "bk65-rx", source: { address: q }, credit_window: 1 });
    let done = false;
    const finish = function (r) { if (!done) { done = true; resolve(r); } };
    rx.once("receiver_error", function (ctx) {
      const e = (ctx && ctx.error) || rx.error || null;
      finish({ error: (e && e.condition) || "receiver_error", description: e && e.description });
    });
    rx.once("message", function (ctx) {
      const body = ctx.message.body;
      const content = typeof body === "string" ? body :
        (body && body.content !== undefined ? String(body.content) : String(body));
      try { ctx.delivery.accept(); } catch (e) { console.log("[dbg] accept: " + e.message); }
      try { rx.close(); } catch (e) {}
      finish({ body: content });
    });
    // SLEEP-CLASS: POLL-STEP — deadline guard bounding the receive event wait; typed failure on expiry.
    setTimeout(function () { finish({ error: "timeout" }); }, 10000);
  });
}

async function main() {
  let fail = 0;

  // Leg 1: ARM PUT namespace + queue q1 -> 201.
  const bearer = await armMintBearer(ARM_PORT);
  await armDelete(ARM_PORT, bearer, "/queues/" + Q1);
  const nsStatus = await armPut(ARM_PORT, bearer, "", { location: "smalt", sku: { name: "Standard" }, properties: {} });
  const q1Status = await armPut(ARM_PORT, bearer, "/queues/" + Q1, { location: "smalt", properties: {} });
  console.log((nsStatus === 201 ? "PASS" : "FAIL") + " arm-ns-put: status=" + nsStatus);
  console.log((q1Status === 201 ? "PASS" : "FAIL") + " arm-q1-put: status=" + q1Status);
  if (nsStatus !== 201) fail++;
  if (q1Status !== 201) fail++;

  // Leg 2: rhea send to ARM-created q1 -> accepted (materialized entity, no auto-ensure).
  const c2 = conn0();
  const sent = await sendLeg(c2, Q1);
  if (sent.tx) { try { sent.tx.close(); } catch (e) {} }
  console.log((sent.accepted === true ? "PASS" : "FAIL") + " rhea-send-q1: accepted=" + sent.accepted +
    " condition=" + (sent.condition || "-") + " desc=" + String(sent.description || "").slice(0, 60));
  if (sent.accepted !== true) fail++;

  // Leg 3: receive + complete -> payload byte-exact. Drain first: earlier
  // probe runs' deliveries may still be in the store (ARM DELETE does not
  // purge the AMQP message store; surfaced in the receipt).
  let got = null;
  let exact = false;
  let drained = 0;
  for (let i = 0; i < 4 && !exact; i++) {
    got = await receiveLeg(c2, Q1);
    if (got.error) break;
    drained++;
    exact = got.body === PAYLOAD;
  }
  console.log((exact ? "PASS" : "FAIL") + " rhea-receive-q1: drained=" + drained +
    " len=" + String((got && got.body) || "").length + "/" + PAYLOAD.length +
    " exact=" + exact + " err=" + ((got && got.error) || "-"));
  if (!exact) fail++;

  // Leg 4: never-created q2 -> amqp:not-found detach + MessagingEntityNotFound;
  // then the SAME connection sends to q1 again (connection survives).
  const c4 = conn0();
  const refused = await sendLeg(c4, Q2);
  const refusedOk = refused.accepted === false &&
    String(refused.condition) === "amqp:not-found" &&
    /MessagingEntityNotFound/i.test(String(refused.description));
  console.log((refusedOk ? "PASS" : "FAIL") + " neg-q2-refusal: condition=" + refused.condition +
    " desc=" + String(refused.description || "").slice(0, 80));
  if (!refusedOk) fail++;
  const survive = await sendLeg(c4, Q1);
  if (survive.tx) { try { survive.tx.close(); } catch (e) {} }
  console.log((survive.accepted === true ? "PASS" : "FAIL") + " neg-conn-survives: accepted=" + survive.accepted);
  if (survive.accepted !== true) fail++;
  try { c4.close(); } catch (e) {}
  try { c2.close(); } catch (e) {}

  process.exit(fail === 0 ? 0 : 1);
}

main().catch(function (e) { console.error("bk65 probe error:", e.message); process.exit(1); });
