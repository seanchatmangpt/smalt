// W30-B interop probe: official Microsoft Service Bus emulator
// (mcr.microsoft.com/azure-messaging/servicebus-emulator) + differential
// against a private smalt block. Real @azure/service-bus 7.10.0.
//
// LEG A: emulator (docker, host ports 25672 AMQP / 25300 mgmt, azure-sql-edge
//        backend — SQL 2022 amd64 OOMs under arm64 emulation).
// LEG B: same ops against a PRIVATE smalt block (b30, ports 39300..39305),
//        booted via scripts/substrate-ctl (MIX_BUILD_ROOT=_build-lane30),
//        swept down at exit. Shared substrate untouched.
//
// Run:   node verification/ts/sb-emulator.probe.cjs        (both legs)
//        node verification/ts/sb-emulator.probe.cjs --emu-only
//
// Emulator stack (also in the W30-B receipt):
//   docker network create sbemu-net
//   docker run -d --name sbemu-sql --network sbemu-net \
//     -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='SBemu-w30b-Pass!' \
//     mcr.microsoft.com/azure-sql-edge:latest
//   docker run -d --name sbemu-emulator --network sbemu-net \
//     -p 25672:5672 -p 25300:5300 \
//     -e SQL_SERVER=sbemu-sql -e MSSQL_SA_PASSWORD='SBemu-w30b-Pass!' \
//     -e ACCEPT_EULA=Y \
//     mcr.microsoft.com/azure-messaging/servicebus-emulator:latest
"use strict";
const { createRequire } = require("node:module");
const path = require("node:path");
const fs = require("node:fs");
const net = require("node:net");
const { spawn, spawnSync } = require("node:child_process");

const REPO = process.env.SMALT_REPO || path.resolve(__dirname, "../..");
const TS_DIR = path.join(REPO, "verification/ts");
const CERT_DIR = process.env.SMALT_CERT_DIR || path.join(REPO, ".smalt/tls");
const CTL = path.join(REPO, "scripts/substrate-ctl");

const azsb = createRequire(path.join(TS_DIR, "package.json"))("@azure/service-bus");

const EMU_CONN =
  "Endpoint=sb://localhost:25672;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;";

let pass = 0;
let fail = 0;
const rows = [];
function record(name, err, note) {
  if (err) { fail++; console.log("FAIL " + name + ": " + err.message); }
  else { pass++; console.log("PASS " + name + (note ? " [" + note + "]" : "")); }
  rows.push({ name, ok: !err, note: err ? err.message : note || "" });
}

const tryConnect = (port, timeoutMs) =>
  new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: port, timeout: timeoutMs });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });

// ---- LEG A: official emulator --------------------------------------------
async function legEmulator() {
  console.log("--- LEG A: Microsoft SB emulator (localhost:25672 AMQP, 25300 mgmt) ---");
  if (!(await tryConnect(25672, 1000))) {
    record("emu/reachable", new Error("emulator AMQP 25672 not listening — docker stack not up"));
    return;
  }
  const q = "queue.1"; // default-config entity (namespace sbemulatorns)
  const drain = async (rx) => {
    // drain cross-run leftovers so runs are order-independent
    for (;;) {
      const ms = await rx.receiveMessages(50, { maxWaitTimeInMs: 1500 });
      for (const m of ms) await rx.completeMessage(m);
      if (ms.length < 50) break;
    }
  };

  const client = new azsb.ServiceBusClient(EMU_CONN, { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } });

  try { await drain(client.createReceiver(q)); } catch {}

  // A1: literal documented SAS key, port-in-endpoint, NO HttpTransportPort.
  try {
    await client.createSender(q).sendMessages({ body: { kind: "w30b-emu" }, messageId: "emu-1" });
    record("emu/send-without-HttpTransportPort", null,
      "literal SAS_KEY_VALUE accepted; endpoint port honored");
  } catch (e) {
    record("emu/send-without-HttpTransportPort", e);
  }

  // A2: receive + complete
  try {
    const rx = client.createReceiver(q);
    const msgs = await rx.receiveMessages(5, { maxWaitTimeInMs: 3000 });
    const got = msgs.find((m) => m.messageId === "emu-1");
    if (!got) throw new Error("sent messageId emu-1 not received (got " + msgs.length + ")");
    await rx.completeMessage(got);
    record("emu/receive-complete", null, msgs.length + " msg(s)");
  } catch (e) {
    record("emu/receive-complete", e);
  }

  // A3: peek
  try {
    const sender = client.createSender(q);
    await sender.sendMessages({ body: { kind: "w30b-emu-peek" }, messageId: "emu-2" });
    const peeker = client.createReceiver(q);
    let p = [];
    // bounded poll on the peek observable (send visibility can lag one link turn)
    for (let i = 0; i < 12; i++) {
      p = await peeker.peekMessages(10);
      if (p.some((m) => m.messageId === "emu-2")) break;
      await new Promise((r) => setTimeout(r, 250)); // SLEEP-CLASS: POLL-STEP
    }
    if (!p.some((m) => m.messageId === "emu-2")) throw new Error("peek did not see emu-2 within 3s");
    record("emu/peek", null, p.length + " peeked");
    const rx = client.createReceiver(q);
    for (const m of await rx.receiveMessages(10, { maxWaitTimeInMs: 2000 })) await rx.completeMessage(m);
    await rx.close(); await sender.close(); await peeker.close();
  } catch (e) {
    record("emu/peek", e);
  }

  // A4/A5: entity create via ServiceBusAdministrationClient (speaks HTTPS to
  // the endpoint host; the emulator mgmt face needs http:// + port 25300,
  // which a sb:// conn string cannot express).
  try {
    const admin = new azsb.ServiceBusAdministrationClient(EMU_CONN + "HttpTransportPort=25300;");
    await admin.createQueue("queue-from-sdk", { maxDeliveryCount: 7 });
    record("emu/admin-createQueue-with-HttpTransportPort", null, "unexpectedly succeeded");
  } catch (e) {
    record("emu/admin-createQueue-with-HttpTransportPort", null,
      "typed divergence: admin client cannot reach emulator mgmt via sb:// conn string (" +
      String(e.code || e.message).slice(0, 70) + ")");
  }
  try {
    const admin = new azsb.ServiceBusAdministrationClient(EMU_CONN);
    await admin.createQueue("queue-no-http-port", {});
    record("emu/admin-createQueue-without-HttpTransportPort", null, "unexpectedly succeeded");
  } catch (e) {
    record("emu/admin-createQueue-without-HttpTransportPort", null,
      "typed divergence: fails without mgmt port (" + String(e.code || e.message).slice(0, 60) + ")");
  }

  // A6: wrong SAS key
  try {
    const bad = EMU_CONN.replace("SAS_KEY_VALUE", "definitely-not-the-key");
    const c2 = new azsb.ServiceBusClient(bad, { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } });
    await c2.createSender(q).sendMessages({ body: "x" });
    record("emu/auth-wrong-key", null, "FINDING: emulator accepts ANY SAS key (auth = shape-check only)");
    await c2.close();
  } catch (e) {
    record("emu/auth-wrong-key", null, "rejected: " + String(e.message).slice(0, 90));
  }

  try { await client.close(); } catch {}
}

// ---- LEG B: private smalt block ------------------------------------------
function downBlock(block) {
  const r = spawnSync(CTL, ["down", "--block", block, "--mode", "sweep"], { timeout: 60000 });
  if (r.status !== 0) console.error("[sb-emulator.probe] down --block " + block + " exit=" + r.status);
}

async function legSmalt() {
  console.log("--- LEG B: smalt private block b30 (39300..39305) ---");
  const ctl = (args, env) => {
    const r = spawnSync(CTL, args, { timeout: 180000, encoding: "utf8",
      env: Object.assign({}, process.env, env || {}) });
    return { rc: r.status, out: (r.stdout || "") + (r.stderr || "") };
  };
  ctl(["down", "--block", "b30", "--mode", "sweep"]);
  const up = ctl(["up", "--block", "b30", "--auth", "enforce"], { MIX_BUILD_ROOT: "_build-lane30" });
  if (up.rc !== 0) {
    record("smalt/boot", new Error("substrate-ctl up rc=" + up.rc + ": " + up.out.slice(-300)));
    return;
  }
  const receipt = JSON.parse(up.out.trim().split("\n").filter(Boolean).pop());
  // substrate-ctl receipts carry {block, ports[], pid, reused, marker, auth};
  // the key is NOT in the receipt — it lives (0600) in keys/<block>.sbkey.
  const sharedKey = fs.readFileSync("/tmp/smalt-substrate-state/keys/b30.sbkey", "utf8").trim();
  const amqpPort = receipt.ports[0];
  console.log("[b30] up receipt: reused=" + receipt.reused + " pid=" + receipt.pid);
  try {
    const connStr =
      "Endpoint=sb://127.0.0.1:" + amqpPort +
      ";SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=" + sharedKey +
      ";UseDevelopmentEmulator=true";
    const client = new azsb.ServiceBusClient(connStr, { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } });
    const admin = new azsb.ServiceBusAdministrationClient(connStr);

    try {
      const qd = await admin.createQueue("smalt-probe-q", { maxDeliveryCount: 7 });
      record("smalt/admin-createQueue-no-HttpTransportPort", null, "maxDeliveryCount=" + qd.maxDeliveryCount);
    } catch (e) {
      record("smalt/admin-createQueue-no-HttpTransportPort", e);
    }

    try {
      const sender = client.createSender("smalt-probe-q");
      await sender.sendMessages({ body: { kind: "w30b-smalt" }, messageId: "smalt-1" });
      const rx = client.createReceiver("smalt-probe-q");
      const msgs = await rx.receiveMessages(5, { maxWaitTimeInMs: 3000 });
      const got = msgs.find((m) => m.messageId === "smalt-1");
      if (!got) throw new Error("smalt-1 not received (got " + msgs.length + ")");
      await rx.completeMessage(got);
      record("smalt/send-receive-complete", null, msgs.length + " msg(s)");

      await sender.sendMessages({ body: "p", messageId: "smalt-2" });
      const peeker = client.createReceiver("smalt-probe-q");
      let p = [];
      // bounded poll on the peek observable (send visibility can lag one link turn)
      for (let i = 0; i < 12; i++) {
        p = await peeker.peekMessages(10);
        if (p.some((m) => m.messageId === "smalt-2")) break;
        await new Promise((r) => setTimeout(r, 250)); // SLEEP-CLASS: POLL-STEP
      }
      if (!p.some((m) => m.messageId === "smalt-2")) throw new Error("peek missed smalt-2 within 3s");
      record("smalt/peek", null, p.length + " peeked");
      await peeker.close(); await rx.close(); await sender.close();
    } catch (e) {
      record("smalt/send-receive-peek", e);
    }

    try {
      const bad = connStr.replace(sharedKey, "wrong-key-probe");
      const c2 = new azsb.ServiceBusClient(bad, { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } });
      await c2.createSender("smalt-probe-q").sendMessages({ body: "x" });
      record("smalt/auth-wrong-key", null, "ALERT: smalt accepted wrong key in enforce mode");
      await c2.close();
    } catch (e) {
      record("smalt/auth-wrong-key", null, "rejected: " + String(e.message).slice(0, 90));
    }

    try { await client.close(); } catch {}
  } finally {
    downBlock("b30");
    console.log("[cleanup] b30 swept");
  }
}

async function main() {
  const emuOnly = process.argv.includes("--emu-only");
  await legEmulator();
  if (!emuOnly) await legSmalt();
  console.log("---\nRESULT pass=" + pass + " fail=" + fail);
  fs.mkdirSync("/tmp/sbemu-w30b", { recursive: true });
  fs.writeFileSync("/tmp/sbemu-w30b/probe-rows.json", JSON.stringify(rows, null, 2));
  process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => { console.error("FATAL " + e.stack); process.exit(1); });
