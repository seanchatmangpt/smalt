// KD-115 falsifier probe — credit-first receiver starvation over the real
// AMQP wire (rhea 3.0.5), against a PRIVATE substrate (block b13, swept at
// exit; never touches the shared substrate). Mirrors kd85.probe.cjs.
//
//   node verification/ts/kd115.probe.cjs        // exit 0 pass / 1 fail
//
// Pre-fix (deliver_available/1 ran only on :flow) the receive leg starves:
// attach -> flow(credit) BEFORE any message exists, then send — no delivery
// ever arrives. Post-fix the enqueue re-runs the dispatch and the transfer
// arrives with no further client flow. Session face: the same leg with a
// com.microsoft:session-filter receiver and group_id sends.
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
const types = rhea.types;
const CTL = path.join(REPO, "scripts/substrate-ctl");
const BLOCK = process.env.KD115_BLOCK || "b13";

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
  const sharedKey = Buffer.from(block + "-" + Date.now() + "-kd115").toString("base64");
  const bootEval =
    'Application.put_env(:smalt, :sb_shared_key, "' + sharedKey + '"); ' +
    'Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:' + ports[0] + '"); ' +
    'Application.put_env(:smalt, :amqp_port, ' + ports[0] + '); ' +
    'Application.put_env(:smalt, :event_hubs_port, ' + ports[1] + '); ' +
    'Application.put_env(:smalt, :arm_port, ' + ports[2] + '); ' +
    'Application.put_env(:smalt, :egress_port, ' + ports[3] + '); ' +
    'Application.put_env(:smalt, :arm_tls_port, ' + ports[4] + '); ' +
    'Application.put_env(:smalt, :mcp_port, ' + ports[5] + '); ' +
    // KD-86 real-SB parity flipped enqueue to refuse never-created entities
    // (MessagingEntityNotFound); this probe has no admin-client path (raw
    // rhea), so the private substrate rides the documented emulator escape
    // hatch. Entity create-on-send is the probe fixture, not the law.
    'Application.put_env(:smalt, :sb_auto_ensure, true); ' +
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
    // SLEEP-CLASS: POLL-STEP (substrate readiness boot poll, 250ms cadence)
    await new Promise((r) => setTimeout(r, 250));  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
  }
  return { ports: ports, sharedKey: sharedKey };
}

function mintToken(audience, key, ttlSec = 3600) {
  // smalt pins string-to-sign over the URL-ENCODED sr (SasVerifier wire fix)
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
    setTimeout(() => reject(new Error("put-token timeout")), 8000);  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
  });
}

function sessionFilterSource(addr, sid) {
  return {
    source: {
      address: addr,
      filter: { "com.microsoft:session-filter": types.wrap_described(sid, "com.microsoft:session-filter") }
    }
  };
}

async function creditFirstLeg(conn, q, sid) {
  // 1. session-filter receiver FIRST: attach + flow credit BEFORE any message.
  const src = sid ? sessionFilterSource(q, sid) : q;
  const rx = conn.open_receiver(src);
  await new Promise((res, rej) => { rx.once("receiver_open", res); rx.once("detach", rej); });
  rx.add_credit(10);
  const got = [];
  rx.on("message", (c) => { got.push(c.message); c.delivery.accept(); });

  // 2. sender link on the SAME connection, messages AFTER credit.
  const tx = conn.open_sender(q);
  await new Promise((res) => tx.once("sendable", res));
  for (let i = 0; i < 3; i++) {
    const msg = { body: "m" + i, application_properties: { n: i }, message_id: "mid-" + i };
    if (sid) msg.group_id = sid;
    tx.send(msg);
  }
  // 3. falsifier: deliveries arrive with NO further client flow.
  const deadline = Date.now() + 6000;
  while (got.length < 3 && Date.now() < deadline) {
    // SLEEP-CLASS: POLL-STEP (bounded delivery poll on the real observable)
    await new Promise((r) => setTimeout(r, 100));  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
  }
  rx.close(); tx.close();
  return got.length;
}

async function main() {
  const booted = process.env.KD115_AMQP_PORT
    ? { ports: [Number(process.env.KD115_AMQP_PORT)], sharedKey: process.env.KD115_SHARED_KEY }
    : await bootPrivate(BLOCK);
  const amqp = booted.ports[0];
  const conn = rhea.connect({ host: "127.0.0.1", port: amqp, username: "anonymous", reconnect: false });
  conn.on("connection_error", (c) => console.log("conn-error", c.error && c.error.condition, c.error && c.error.description));
  await new Promise((r) => conn.once("connection_open", r));

  const legs = [
    { name: "plain-credit-first", q: "kd115-plain", sid: null },
    { name: "session-credit-first", q: "kd115-sess", sid: "s1" }
  ];

  let fail = 0;
  for (const leg of legs) {
    const aud = "sb://127.0.0.1:" + amqp + "/" + leg.q;
    await putToken(conn, aud, mintToken(aud, booted.sharedKey));
    const n = await creditFirstLeg(conn, leg.q, leg.sid);
    const ok = n === 3;
    console.log((ok ? "PASS " : "FAIL ") + leg.name + ": received " + n + "/3 (credit-first, no reflow)");
    if (!ok) fail++;
  }

  // KD-116 falsifier: session deliveries are SETTLEABLE on the wire —
  // receive 3, accept all, re-receive must be empty.
  try {
    const q = "kd116-settle";
    const aud = "sb://127.0.0.1:" + amqp + "/" + q;
    await putToken(conn, aud, mintToken(aud, booted.sharedKey));
    const tx = conn.open_sender(q);
    await new Promise((r) => tx.once("sendable", r));
    for (let i = 0; i < 3; i++) {
      tx.send({ body: "m" + i, application_properties: { n: i }, message_id: "mid-" + i, group_id: "s1" });
    }
    await new Promise((r) => setTimeout(r, 300));  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
    tx.close();

    const rx = conn.open_receiver(sessionFilterSource(q, "s1"));
    await new Promise((res, rej) => { rx.once("receiver_open", res); rx.once("detach", rej); });
    rx.add_credit(10);
    const got = [];
    rx.on("message", (c) => { got.push(c.message); c.delivery.accept(); });
    const deadline = Date.now() + 5000;
    while (got.length < 3 && Date.now() < deadline) {
      // SLEEP-CLASS: POLL-STEP (bounded delivery poll on the real observable)
      await new Promise((r) => setTimeout(r, 100));  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
    }
    rx.close();
    await new Promise((r) => setTimeout(r, 300));  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)

    const rx2 = conn.open_receiver(sessionFilterSource(q, "s1"));
    const verdict = await new Promise((res) => {
      const got2 = [];
      rx2.on("message", (c) => got2.push(c.message));
      rx2.once("receiver_open", () => rx2.add_credit(10));
      rx2.once("detach", (c) => res(-1));
      const dl = Date.now() + 2500;
      const chk = () => {
        if (Date.now() > dl) return res(got2.length);
        // SLEEP-CLASS: POLL-STEP (bounded re-receive poll, 100ms cadence)
        setTimeout(chk, 100);  // SLEEP-CLASS: POLL-STEP (bounded request/watchdog timeout)
      };
      chk();
    });
    const ok = got.length === 3 && verdict === 0;
    console.log((ok ? "PASS " : "FAIL ") + "kd116-session-settle: settled " + got.length + "/3, re-receive " + verdict + " (expect 0)");
    if (!ok) fail++;
  } catch (e) {
    console.log("FAIL kd116-session-settle: " + e.message);
    fail++;
  }

  conn.close();
  spawnSync(CTL, ["down", "--block", BLOCK, "--mode", "sweep"], { timeout: 60000 });
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("FATAL", e.message);
  spawnSync(CTL, ["down", "--block", BLOCK, "--mode", "sweep"], { timeout: 60000 });
  process.exit(1);
});
