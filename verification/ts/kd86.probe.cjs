// KD-86 falsifier probe — send-path auto-ensure gate over the real AMQP wire
// (rhea 3.0.5), against a PRIVATE substrate (block b27, swept at exit; never
// touches the shared substrate). Mirrors kd115.probe.cjs.
//
//   node verification/ts/kd86.probe.cjs        // exit 0 pass / 1 fail
//
// Legs:
//   kd86-refusal    : sender to a NEVER-created queue → sender link is
//                     detached with error condition amqp:not-found and a
//                     MessagingEntityNotFound description (real-SB contract;
//                     pre-gate the emulator silently auto-created the entity).
//   kd86-arm-create : the same queue ARM-PUT first → send is accepted (the
//                     gate refuses only never-created entities).
"use strict";
const { createRequire } = require("node:module");
const path = require("node:path");
const fs = require("node:fs");
const net = require("node:net");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");

const REPO = process.env.SMALT_REPO || path.resolve(__dirname, "../..");
const TS_DIR = path.join(REPO, "verification/ts");
const rhea = createRequire(path.join(TS_DIR, "package.json"))("rhea");
// Container-level error sink: after a broker error-detach, rhea's scheduled
// link close can meet the broker's detach echo ("Detach already received");
// swallow it at the container so the probe exits on its own verdict only.
const sink = rhea.create_container();
sink.on("error", (e) => console.log("[dbg] container error swallowed: " + e.message));
const types = rhea.types;
const CTL = path.join(REPO, "scripts/substrate-ctl");
const BLOCK = process.env.KD86_BLOCK || "b27";

const tryConnect = (port, timeoutMs) =>
  new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: timeoutMs });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });

async function bootPrivate(block) {
  const base = 39000;
  const ports = [0, 1, 2, 3, 4, 5].map((i) => base + 10 * Number(block.slice(1)) + i);
  spawnSync(CTL, ["down", "--block", block, "--mode", "sweep"], { timeout: 60000 });
  for (const p of ports) {
    if (await tryConnect(p, 500)) throw new Error("block " + block + " port " + p + " occupied");
  }
  const sharedKey = Buffer.from(block + "-" + Date.now() + "-kd86").toString("base64");
  const bootEval =
    'Application.put_env(:smalt, :sb_shared_key, "' + sharedKey + '"); ' +
    'Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:' + ports[0] + '"); ' +
    'Application.put_env(:smalt, :amqp_port, ' + ports[0] + '); ' +
    'Application.put_env(:smalt, :event_hubs_port, ' + ports[1] + '); ' +
    'Application.put_env(:smalt, :arm_port, ' + ports[2] + '); ' +
    'Application.put_env(:smalt, :egress_port, ' + ports[3] + '); ' +
    'Application.put_env(:smalt, :arm_tls_port, ' + ports[4] + '); ' +
    'Application.put_env(:smalt, :mcp_port, ' + ports[5] + '); ' +
    '{:ok, _} = Application.ensure_all_started(:smalt)';
  const logPath = "/tmp/smalt-substrate-state/logs/" + block + ".log";
  fs.mkdirSync("/tmp/smalt-substrate-state/logs", { recursive: true });
  const log = fs.openSync(logPath, "w");
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: Object.assign({}, process.env, {
      MIX_ENV: "test",
      SMALT_TLS_CERTFILE: path.join(REPO, ".smalt/tls/dev-cert.pem"),
      SMALT_TLS_KEYFILE: path.join(REPO, ".smalt/tls/dev-key.pem"),
    }),
    stdio: ["ignore", log, log],
    detached: true,
  });
  child.unref();
  fs.closeSync(log);
  const deadline = Date.now() + 90000;
  for (;;) {
    const up = (await Promise.all(ports.map((p) => tryConnect(p, 500)))).every(Boolean);
    if (up) break;
    if (Date.now() > deadline) throw new Error("private substrate not up in 90s (log: " + logPath + ")");
    await new Promise((r) => setTimeout(r, 250)); // SLEEP-CLASS: POLL-STEP (substrate readiness boot poll)
  }
  return { ports: ports, sharedKey: sharedKey };
}

function mintToken(audience, key, ttlSec = 3600) {
  const se = Math.floor(Date.now() / 1000) + ttlSec;
  const sr = encodeURIComponent(audience);
  const sig = crypto.createHmac("sha256", key).update(sr + "\n" + se).digest("base64");
  return "SharedAccessSignature sr=" + sr + "&sig=" + encodeURIComponent(sig) +
    "&se=" + se + "&skn=RootManageSharedAccessKey";
}

function putToken(conn, audience, token) {
  return new Promise((resolve, reject) => {
    const sender = conn.open_sender("$cbs");
    sender.once("sendable", () => {
      const replyTo = "cbs-reply-" + crypto.randomBytes(4).toString("hex");
      const rx = conn.open_receiver({ name: replyTo, target: { address: replyTo } });
      rx.once("receiver_open", () => {
        rx.add_credit(1);
        sender.send({
          properties: { message_id: "cbs-" + Date.now(), subject: "put-token", to: audience, reply_to: replyTo },
          application_properties: {
            operation: "put-token",
            type: "servicebus.windows.net:sastoken",
            name: audience,
            "reply-to": replyTo
          },
          body: token
        });
        rx.on("message", (c) => {
          const status = c.message.application_properties["status-code"];
          sender.close(); rx.close();
          status === 200 ? resolve(status) : reject(new Error("put-token " + status));
        });
      });
    });
    setTimeout(() => reject(new Error("put-token timeout")), 8000); // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
  });
}

// Send one message to `q`; resolves {accepted, condition, description}:
// accepted = broker disposition accepted; else the sender detach error.
function sendLeg(conn, q, aud, key) {
  return new Promise(async (resolve, reject) => {
    try { await putToken(conn, aud, mintToken(aud, key)); } catch (e) { return reject(e); }
    const tx = conn.open_sender(q);
    let done = false;
    const finish = (r) => {
      if (!done) {
        done = true;
        r.tx = tx;
        resolve(r);
      }
    };
    const readErr = (ctx) => ((ctx && ctx.error) || tx.error || null);
    tx.once("sender_error", (ctx) => {
      const err = readErr(ctx);
      finish({ accepted: false, condition: err && err.condition, description: err && err.description });
    });
    tx.once("sender_close", (ctx) => {
      const err = readErr(ctx);
      finish({ accepted: false, condition: err && err.condition, description: err && err.description });
    });
    tx.once("sendable", () => {
      tx.once("accepted", () => finish({ accepted: true }));
      tx.send({ body: "kd86", message_id: "kd86-" + Date.now() });
    });
    setTimeout(() => finish({ accepted: false, condition: "timeout" }), 10000); // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
  });
}

async function main() {
  const booted = process.env.KD86_AMQP_PORT
    ? { ports: [Number(process.env.KD86_AMQP_PORT), 0, Number(process.env.KD86_ARM_PORT || 0)], sharedKey: process.env.KD86_SHARED_KEY }
    : await bootPrivate(BLOCK);
  const [amqpPort, , armPort] = booted.ports;
  let fail = 0;

  // Leg 1: never-created queue → amqp:not-found detach, MessagingEntityNotFound.
  const refusedQ = "kd86-never-created";
  const refusedAud = "sb://127.0.0.1:" + amqpPort + "/" + refusedQ;
  const refused = await sendLeg(conn0(), refusedQ, refusedAud, booted.sharedKey);
  if (refused.tx) { try { refused.tx.remove(); } catch {} }
  const refusedOk =
    refused.accepted === false &&
    String(refused.condition) === "amqp:not-found" &&
    /MessagingEntityNotFound/i.test(String(refused.description));
  console.log(
    (refusedOk ? "PASS " : "FAIL ") + "kd86-refusal: condition=" + refused.condition +
    " desc=" + String(refused.description).slice(0, 80)
  );
  if (!refusedOk) fail++;

  // Leg 2: ARM-created queue → send accepted (gate refuses only never-created).
  const okQ = "kd86-arm-created";
  const created = await armPutQueue(armPort, okQ);
  const okAud = "sb://127.0.0.1:" + amqpPort + "/" + okQ;
  const accepted = created ? await sendLeg(conn0(), okQ, okAud, booted.sharedKey) : { accepted: false, condition: "arm-put-failed" };
  if (accepted.tx) { try { accepted.tx.remove(); } catch {} }
  const okOk = accepted.accepted === true;
  console.log((okOk ? "PASS " : "FAIL ") + "kd86-arm-create: accepted=" + accepted.accepted + " condition=" + accepted.condition + " desc=" + String(accepted.description || "").slice(0, 60));
  if (!okOk) fail++;

  cleanup();
  process.exit(fail === 0 ? 0 : 1);

  function conn0() {
    const conn = sink.connect({ host: "127.0.0.1", port: amqpPort, username: "anonymous", reconnect: false });
    conn.on("connection_error", (c) => console.log("conn-error", c.error && c.error.condition));
    return conn;
  }
}

async function armPutQueue(armPort, q) {
  // Auth face mirrors the console lib: mint a bearer from the local STS first
  // (enforce-auth ARM refuses anonymous PUTs).
  const tokRes = await fetch("http://127.0.0.1:" + armPort + "/dev/oauth2/v2.0/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "kd86-probe",
      client_secret: "kd86",
      scope: "https://management.azure.com/.default",
    }).toString(),
  });
  if (!tokRes.ok) return false;
  const { access_token: token } = await tokRes.json();
  if (!token) return false;
  const armBase = "http://127.0.0.1:" + armPort +
    "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/kd86-rg/providers/" +
    "Microsoft.ServiceBus/namespaces/kd86-ns";
  const put = (path, body) => fetch(armBase + path, {
    method: "PUT",
    headers: { authorization: "Bearer " + token, "content-type": "application/json" },
    body: JSON.stringify(body)
  }).then((r) => r.ok);
  // namespace first (graphlaw shape: sku required), then the queue child
  const nsOk = await put("?api-version=2021-04-01", { location: "smalt", sku: { name: "Standard" }, properties: {} });
  if (!nsOk) return false;
  return put("/queues/" + q + "?api-version=2021-04-01", { location: "smalt", properties: {} });
}

let bootedState = null;
function cleanup() {
  if (bootedState) return;
  spawnSync(CTL, ["down", "--block", process.env.KD86_BLOCK || "b27", "--mode", "sweep"], { timeout: 60000 });
}

main().catch((e) => { console.error("kd86 probe error:", e.message); cleanup(); process.exit(1); });
