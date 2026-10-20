// Supplementary Service Bus SDK probes (census supplement, lane b11).
// Real @azure/service-bus 7.10.0 from verification/ts/node_modules against
// the smalt substrate. Standalone:
//   SMALT_SB_SHARED_KEY=... SMALT_SB_CONNECTION_STRING=... \
//     node verification/ts/sb-extra.probe.cjs
// With no credentials in env it boots its OWN private substrate (block b11,
// ts-run.mjs boot-eval shape, same lift as census.test.cjs) and sweeps it
// down at exit.
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

let pass = 0;
let fail = 0;
function record(name, err) {
  if (err) {
    fail++;
    console.log("FAIL " + name + ": " + err.message);
  } else {
    pass++;
    console.log("PASS " + name);
  }
}

const tryConnect = (port, timeoutMs) =>
  new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: port, timeout: timeoutMs });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });

async function bootPrivate(block) {
  const m = /^([bv])(\d+)$/.exec(block);
  if (!m) throw new Error("unknown block " + block);
  const base = m[1] === "v" ? 39700 : 39000;
  const ports = [0, 1, 2, 3, 4, 5].map((i) => base + 10 * Number(m[2]) + i);
  spawnSync(CTL, ["down", "--block", block, "--mode", "sweep"], { timeout: 60000 });
  for (const p of ports) {
    const held = await tryConnect(p, 500);
    if (held) throw new Error("block " + block + " port " + p + " occupied by non-sweepable listener");
  }
  const caCert = path.join(CERT_DIR, "ca-cert.pem");
  if (!fs.existsSync(caCert)) throw new Error("missing TLS CA — run bash scripts/gen_dev_cert.sh");
  const amqp = ports[0];
  const eh = ports[1];
  const arm = ports[2];
  const egress = ports[3];
  const tls = ports[4];
  const mcp = ports[5];
  const sharedKey = Buffer.from(block + "-" + Date.now() + "-sb-extra").toString("base64");
  const bootEval =
    'Application.put_env(:smalt, :sb_shared_key, "' + sharedKey + '"); ' +
    'Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:' + amqp + '"); ' +
    'Application.put_env(:smalt, :amqp_port, ' + amqp + '); ' +
    'Application.put_env(:smalt, :event_hubs_port, ' + eh + '); ' +
    'Application.put_env(:smalt, :arm_port, ' + arm + '); ' +
    'Application.put_env(:smalt, :egress_port, ' + egress + '); ' +
    'Application.put_env(:smalt, :arm_tls_port, ' + tls + '); ' +
    'Application.put_env(:smalt, :mcp_port, ' + mcp + '); ' +
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
      ? await fetch("http://127.0.0.1:" + arm + "/metadata/endpoints").then((r) => r.status).catch(() => 0)
      : 0;
    if (up && health === 200) break;
    if (Date.now() > deadline) {
      throw new Error("private substrate " + block + " not healthy in 90s (log: " + logPath + ")");
    }
    // SLEEP-CLASS: POLL-STEP — substrate boot readiness poll
    await new Promise((r) => setTimeout(r, 250));
  }
  return { ports: ports, sharedKey: sharedKey, pid: child.pid };
}

function downBlock(block) {
  const res = spawnSync(CTL, ["down", "--block", block, "--mode", "sweep"], { timeout: 60000 });
  if (res.status !== 0) console.error("[sb-extra] down --block " + block + " exit=" + res.status);
}

async function main() {
  const key = process.env.SMALT_SB_SHARED_KEY;
  let booted = null;
  let connStr = null;
  if (!key) {
    booted = await bootPrivate("b11");
    connStr =
      "Endpoint=sb://127.0.0.1:" + booted.ports[0] +
      ";SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=" + booted.sharedKey +
      ";UseDevelopmentEmulator=true";
  } else {
    connStr = process.env.SMALT_SB_CONNECTION_STRING;
    if (!connStr) process.exit(3);
  }

  const client = new azsb.ServiceBusClient(connStr, { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } });
  const admin = new azsb.ServiceBusAdministrationClient(connStr);
  const queue = "sb-extra-census";
  try {
    await admin.createQueue(queue, {});
  } catch (e) {
    // exists is fine
  }

  const sender = client.createSender(queue);

  // probe 1: scheduleMessage — invisible before ScheduledEnqueueTime, delivered after
  try {
    const at = new Date(Date.now() + 2000);
    await sender.scheduleMessages([{ body: { kind: "sb-extra" }, messageId: "extra-sched-1" }], at);
    const rx = client.createReceiver(queue);
    const early = await rx.receiveMessages(10, { maxWaitTimeInMs: 1500 });
    let err = null;
    if (early.some((m) => m.messageId === "extra-sched-1")) {
      err = new Error("visible before ScheduledEnqueueTime");
    } else {
      // SLEEP-CLASS: TIME-ADVANCE — PT2S lock-duration law under test (broker-side expiry, not coordination)
      await new Promise((r) => setTimeout(r, 2500));
      const late = await rx.receiveMessages(10, { maxWaitTimeInMs: 3000 });
      if (!late.some((m) => m.messageId === "extra-sched-1")) {
        err = new Error("scheduled message never delivered after delay");
      }
    }
    await rx.close();
    record("scheduleMessage", err);
  } catch (e) {
    record("scheduleMessage", e);
  }

  // probe 2: receiveAndDelete delivery
  try {
    await sender.sendMessages([{ body: { kind: "sb-extra" }, messageId: "extra-fire-1" }]);
    const rx = client.createReceiver(queue, { receiveMode: "receiveAndDelete" });
    const msgs = await rx.receiveMessages(1, { maxWaitTimeInMs: 3000 });
    if (msgs.length === 0) throw new Error("no delivery");
    if (msgs[0].messageId !== "extra-fire-1") throw new Error("wrong message " + msgs[0].messageId);
    await rx.close();
    record("receiveAndDelete-delivery", null);
  } catch (e) {
    record("receiveAndDelete-delivery", e);
  }

  // probe 3: acceptNextSession on a sessionless queue — broker must refuse;
  // an accepted session here is a probe failure.
  try {
    const sessRx = await client.acceptNextSession(queue, { maxWaitTimeInMs: 2000 });
    await sessRx.close();
    record("acceptNextSession-no-session", new Error("unexpected session accepted"));
  } catch (e) {
    if (e.message === "unexpected session accepted") throw e;
    record("acceptNextSession-no-session", null);
  }

  await sender.close();
  await client.close();
  console.log("SUMMARY pass=" + pass + " fail=" + fail);
  process.exitCode = fail === 0 ? 0 : 1;
  if (booted) downBlock("b11");
}


// Hard top-level watchdog: the AMQP attach can hang past retryOptions
// timeoutInMs against a draining broker (witnessed: two orphaned probe
// processes idling against a swept substrate during the v26.10.19 court).
const WATCHDOG_MS = parseInt(process.env.SMALT_SB_EXTRA_WATCHDOG_MS || "180000", 10);
const watchdog = setTimeout(function () { // SLEEP-CLASS: SCHEDULING (hard top-level watchdog, typed exit 3)
  console.error("[sb-extra] WATCHDOG: no verdict in " + WATCHDOG_MS + "ms — typed fail");
  downBlock("b11");
  process.exit(3);
}, WATCHDOG_MS);
watchdog.unref();

main().catch(function (e) {
  console.error("harness:", e);
  downBlock("b11");
  process.exit(1);
});
