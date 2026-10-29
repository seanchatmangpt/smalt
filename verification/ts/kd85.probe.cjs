// KD-85 witness probe — real @azure/service-bus 7.10 reads a real enqueued
// timestamp end-to-end against the smalt substrate. Boots its OWN private
// substrate (block b11, ports 39100-39105, same shape as sb-extra.probe.cjs)
// and sweeps it down at exit — never touches the shared substrate.
//   node verification/ts/kd85.probe.cjs
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

let pass = 0, fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + err.message); }
  else { pass++; console.log("PASS " + name); }
}

const tryConnect = (port, timeoutMs) =>
  new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: port, timeout: timeoutMs });
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
  const caCert = path.join(CERT_DIR, "ca-cert.pem");
  if (!fs.existsSync(caCert)) throw new Error("missing TLS CA — run bash scripts/gen_dev_cert.sh");
  const sharedKey = Buffer.from(block + "-" + Date.now() + "-kd85").toString("base64");
  const bootEval =
    'Application.put_env(:smalt, :sb_shared_key, "' + sharedKey + '"); ' +
    'Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:' + ports[0] + '"); ' +
    'Application.put_env(:smalt, :amqp_port, ' + ports[0] + '); ' +
    'Application.put_env(:smalt, :event_hubs_port, ' + ports[1] + '); ' +
    'Application.put_env(:smalt, :arm_port, ' + ports[2] + '); ' +
    'Application.put_env(:smalt, :egress_port, ' + ports[3] + '); ' +
    'Application.put_env(:smalt, :arm_tls_port, ' + ports[4] + '); ' +
    'Application.put_env(:smalt, :mcp_port, ' + ports[5] + '); ' +
    'Application.put_env(:smalt, :auth_mode, :enforce); ' +
    '{:ok, _} = Application.ensure_all_started(:smalt)';
  const logPath = "/tmp/smalt-substrate-state/logs/" + block + ".log";
  fs.mkdirSync("/tmp/smalt-substrate-state/logs", { recursive: true });
  const log = fs.openSync(logPath, "w");
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: Object.assign({}, process.env, {
      MIX_ENV: "test",
      SMALT_TLS_CERTFILE: path.join(CERT_DIR, "dev-cert.pem"),
      SMALT_TLS_KEYFILE: path.join(CERT_DIR, "dev-key.pem"),
    }),
    stdio: ["ignore", log, log],
    detached: true,
  });
  child.unref();
  fs.closeSync(log);
  const deadline = Date.now() + 90000;
  for (;;) {
    const up = (await Promise.all(ports.map((p) => tryConnect(p, 500)))).every(Boolean);
    const health = up
      ? await fetch("http://127.0.0.1:" + ports[2] + "/metadata/endpoints").then((r) => r.status).catch(() => 0)
      : 0;
    if (up && health === 200) break;
    if (Date.now() > deadline) throw new Error("private substrate not healthy in 90s (log: " + logPath + ")");
    // SLEEP-CLASS: POLL-STEP (substrate readiness boot poll, 250ms cadence)
    await new Promise((r) => setTimeout(r, 250));
  }
  return { ports: ports, sharedKey: sharedKey };
}

function downBlock(block) {
  const res = spawnSync(CTL, ["down", "--block", block, "--mode", "sweep"], { timeout: 60000 });
  if (res.status !== 0) console.error("[kd85] down --block " + block + " exit=" + res.status);
}

async function main() {
  const booted = await bootPrivate("b11");
  const connStr =
    "Endpoint=sb://127.0.0.1:" + booted.ports[0] +
    ";SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=" + booted.sharedKey +
    ";UseDevelopmentEmulator=true";

  const client = new azsb.ServiceBusClient(connStr, { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } });
  const admin = new azsb.ServiceBusAdministrationClient(connStr);
  const queue = "kd85-witness";
  try { await admin.createQueue(queue, {}); } catch (e) { /* exists fine */ }

  const sender = client.createSender(queue);
  const sentAt = Date.now();
  await sender.sendMessages([{ body: { kind: "kd85" }, messageId: "kd85-1" }]);
  const rx = client.createReceiver(queue, { receiveMode: "receiveAndDelete" });
  const msgs = await rx.receiveMessages(1, { maxWaitTimeInMs: 5000 });
  if (msgs.length === 0) throw new Error("no delivery");
  const m = msgs[0];
  const et = m.enqueuedTimeUtc;
  if (et instanceof Date && !Number.isNaN(et.getTime()) && Math.abs(et.getTime() - sentAt) < 120000) {
    record("enqueuedTimeUtc-real-Date", null);
    console.log("  enqueuedTimeUtc=" + et.toISOString() + " (send skew " + Math.abs(et.getTime() - sentAt) + "ms)");
  } else {
    record("enqueuedTimeUtc-real-Date", new Error("not a valid Date near send time: " + String(et)));
  }
  // Raw application annotations: 7.10 surfaces them on the internal raw message.
  const ann = (m._rawAmqpMessage && m._rawAmqpMessage.messageAnnotations) || m.amqpAnnotatedProperties || null;
  if (ann && ann["x-opt-enqueued-time"] && ann["x-opt-enqueued-time-utc"]) {
    record("dual-stamp-annotations", null);
    console.log("  x-opt-enqueued-time=" + JSON.stringify(ann["x-opt-enqueued-time"]) +
      " x-opt-enqueued-time-utc=" + JSON.stringify(ann["x-opt-enqueued-time-utc"]));
  } else {
    record("dual-stamp-annotations",
      new Error("SDK surfaced annotations without both stamps: " + JSON.stringify(ann)));
  }
  await rx.close();
  await sender.close();
  await client.close();
  console.log("SUMMARY pass=" + pass + " fail=" + fail);
  process.exitCode = fail === 0 ? 0 : 1;
  downBlock("b11");
}

const watchdog = setTimeout(function () {  // SLEEP-CLASS: POLL-STEP (bounded receipt watchdog)
  console.error("[kd85] WATCHDOG: no verdict in 180s — typed fail");
  downBlock("b11");
  process.exit(3);
}, 180000);
watchdog.unref();

main().catch(function (e) {
  console.error("harness:", e);
  downBlock("b11");
  process.exit(1);
});
