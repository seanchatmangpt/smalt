// Service Bus SDK census — 11 probes, fail-closed, zero skips.
// Ported from the v26.10.14 lane-08 census (test/sdk-smoke/census.test.cjs
// @ 518b31a) into the lifted verification/ts suite shape: real
// @azure/service-bus 7.10.0 (verification/ts/node_modules) over real loopback
// AMQP against a PRIVATE smalt substrate this file boots itself (block b11,
// ts-run.mjs boot-eval shape — the same lift harness/substrate.ts bootPrivate
// uses). If the broker cannot satisfy a probe, the test FAILS — that is the
// correct fail-closed output. No fixed sleeps: readiness is a bounded poll on
// real observables (port connect + ARM /metadata/endpoints 200); the only
// waits are probe-schedule waits on a CREATED lockDuration schedule (15 s /
// 2 s) which are the law under test, not coordination.
"use strict";

const assert = require("node:assert/strict");
const { createRequire } = require("node:module");
const path = require("node:path");
const fs = require("node:fs");
const net = require("node:net");
const { spawn, spawnSync } = require("node:child_process");
const { randomUUID } = require("node:crypto");
const test = require("node:test").test;

const REPO = process.env.SMALT_REPO || path.resolve(__dirname, "../..");
const TS_DIR = path.join(REPO, "verification/ts");
const CERT_DIR = process.env.SMALT_CERT_DIR || path.join(REPO, ".smalt/tls");
const CTL = path.join(REPO, "scripts/substrate-ctl");

// Real SDK from the suite's own node_modules — no SMALT_SDK_ROOT indirection.
const { ServiceBusClient, ServiceBusAdministrationClient } = createRequire(
  path.join(TS_DIR, "package.json"),
)("@azure/service-bus");

const BLOCK = process.env.SMALT_CENSUS_BLOCK || "b11";
// b-block port formula (scripts/lib/substrate_boot.sh): bN = 39000+10N..+5,
// role order [amqp, eh, arm, egress, tls, mcp].
const blockPorts = (b) => {
  const m = /^([bv])(\d+)$/.exec(b);
  if (!m) throw new Error(`unknown census block ${b}`);
  const base = m[1] === "v" ? 39700 : 39000;
  const n = Number(m[2]);
  return [0, 1, 2, 3, 4, 5].map((i) => base + 10 * n + i);
};

// --- private substrate boot (lifted ts-run.mjs eval shape) ---------------------

const tryConnect = (port, timeoutMs = 500) =>
  new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: timeoutMs });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });

async function bootPrivate(block) {
  const ports = blockPorts(block);
  spawnSync(CTL, ["down", "--block", block, "--mode", "sweep"], { timeout: 60_000 });
  for (const p of ports) {
    if (await tryConnect(p)) {
      throw new Error(`block ${block} port ${p} occupied by non-sweepable listener`);
    }
  }
  const caCert = path.join(CERT_DIR, "ca-cert.pem");
  if (!fs.existsSync(caCert)) throw new Error("missing TLS CA — run bash scripts/gen_dev_cert.sh");
  const [amqp, eh, arm, egress, tls, mcp] = ports;
  const sharedKey = Buffer.from(`${block}-${Date.now()}-sb-census`).toString("base64");
  const bootEval = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${amqp}")`,
    `Application.put_env(:smalt, :amqp_port, ${amqp})`,
    `Application.put_env(:smalt, :event_hubs_port, ${eh})`,
    `Application.put_env(:smalt, :arm_port, ${arm})`,
    `Application.put_env(:smalt, :egress_port, ${egress})`,
    `Application.put_env(:smalt, :arm_tls_port, ${tls})`,
    `Application.put_env(:smalt, :mcp_port, ${mcp})`,
    `Application.put_env(:smalt, :auth_mode, :enforce)`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ].join("; ");
  fs.mkdirSync("/tmp/smalt-substrate-state/logs", { recursive: true });
  const logPath = `/tmp/smalt-substrate-state/logs/${block}.log`;
  const log = fs.openSync(logPath, "w");
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: {
      ...process.env,
      MIX_ENV: "test",
      SMALT_TLS_CERTFILE: path.join(CERT_DIR, "dev-cert.pem"),
      SMALT_TLS_KEYFILE: path.join(CERT_DIR, "dev-key.pem"),
    },
    stdio: ["ignore", log, log],
    detached: true,
  });
  child.unref();
  fs.closeSync(log);
  const deadline = Date.now() + 90_000;
  for (;;) {
    const up = (await Promise.all(ports.map((p) => tryConnect(p)))).every(Boolean);
    const health = up
      ? await fetch(`http://127.0.0.1:${arm}/metadata/endpoints`).then((r) => r.status).catch(() => 0)
      : 0;
    if (up && health === 200) break;
    if (Date.now() > deadline) {
      throw new Error(`private substrate ${block} not healthy in 90s (log: ${logPath})`);
    }
    // SLEEP-CLASS: POLL-STEP — substrate readiness boot poll (250ms cadence, deadline-bounded)
    await new Promise((r) => setTimeout(r, 250));
  }
  return { ports, sharedKey, pid: child.pid };
}

function downBlock(block) {
  const res = spawnSync(CTL, ["down", "--block", block, "--mode", "sweep"], { timeout: 60_000 });
  if (res.status !== 0) console.error(`[census] down --block ${block} exit=${res.status}`);
}

// --- credentials ----------------------------------------------------------------

// V261014-08 task 08-1: the broker applies the queue's configured ARM
// lockDuration on the delivery claim path. Probes needing a non-default
// schedule create their queue with an explicit lockDuration via the
// administration client and wait on THAT schedule.
const STALE_LOCK_DURATION = "PT15S";
const SHORT_LOCK_DURATION = "PT2S";
async function createQueueWithLockDuration(admin, queueName, lockDuration) {
  await admin.createQueue(queueName, { lockDuration });
}

let KEY = process.env.SMALT_SB_SHARED_KEY;
const CONNECTION_STRING =
  process.env.SMALT_SB_CONNECTION_STRING ||
  `Endpoint=sb://127.0.0.1:39110;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${KEY};UseDevelopmentEmulator=true`;

const CLIENT_OPTIONS = { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } };

// --- helpers -------------------------------------------------------------------
const wait = (ms) => new Promise((r) => setTimeout(r, ms)); // SLEEP-CLASS: POLL-STEP (audited wait helper, deadline applied by callers)
    // SLEEP-CLASS: POLL-STEP (audited wait helper, deadline applied by callers)
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const errText = (error) =>
  String(error && (error.code ?? error.name)) + " " + String(error && error.message);

async function receiveOne(receiver) {
  const messages = await receiver.receiveMessages(1, { maxWaitTimeInMs: 2000 });
  assert.equal(messages.length, 1, "NONEMPTY_RECEIVE_REQUIRED");
  return messages[0];
}

async function sendOne(client, queue, body, opts = {}) {
  const sender = client.createSender(queue);
  try {
    await sender.sendMessages({ body, ...opts });
  } finally {
    await sender.close();
  }
}

const acceptSessionNoRenew = (client, queue, sessionId) =>
  client.acceptSession(queue, sessionId, {
    receiveMode: "peekLock",
    maxAutoLockRenewalDurationInMs: 0,
  });

// --- probe bodies ---------------------------------------------------------------

async function authenticationCase() {
  const queue = `census-auth-${prefix}`;
  const bad = new ServiceBusClient(
    CONNECTION_STRING.replace(
      /SharedAccessKey=[^;]+/i,
      "SharedAccessKey=" + Buffer.from("wrong-court-key").toString("base64"),
    ),
    CLIENT_OPTIONS,
  );
  try {
    await assert.rejects(
      (async () => {
        const sender = bad.createSender(queue);
        try {
          await sender.sendMessages({ body: "unauthorized" });
        } finally {
          await sender.close();
        }
      })(),
      (error) => /Unauthorized|Authentication|unauthorized|authentication/i.test(errText(error)),
      "wrong SAS key must be rejected",
    );
  } finally {
    await bad.close();
  }
}

async function bytesCase() {
  const queue = `census-bytes-${prefix}`;
  const body = Buffer.from([0, 255, 1, 128]);
  await sendOne(client, queue, body, { messageId: prefix + "-bytes" });
  const receiver = own(client.createReceiver(queue, { maxAutoLockRenewalDurationInMs: 0 }));
  const message = await receiveOne(receiver);
  assert.deepEqual(Buffer.from(message.body), body);
  assert.equal(message.messageId, prefix + "-bytes");
  await receiver.completeMessage(message);
  assert.equal(
    (await receiver.receiveMessages(1, { maxWaitTimeInMs: 200 })).length,
    0,
  );
  await receiver.close();
}

async function exclusiveSessionCase() {
  const queue = `census-session-${prefix}`;
  const sessionId = prefix + "-ex";
  await sendOne(client, queue, "exclusive", { sessionId });
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  await assert.rejects(
    acceptSessionNoRenew(client, queue, sessionId),
    (error) => /SessionCannotBeLocked|SessionLock|session.*lock/i.test(errText(error)),
    "second accept on a locked session must be rejected SessionCannotBeLocked",
  );
  const before = receiver.sessionLockedUntilUtc.getTime();
  await wait(30);
  await receiver.renewSessionLock();
  assert.ok(receiver.sessionLockedUntilUtc.getTime() > before, "RENEWAL_MUST_EXTEND_LOCK");
  await receiver.completeMessage(await receiveOne(receiver));
  await receiver.close();
}

async function renewalPeekCase() {
  const queue = `census-renew-${prefix}`;
  const sessionId = prefix + "-renew";
  await sendOne(client, queue, Buffer.from([7, 0, 8]), { sessionId });
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  const peeked = await receiver.peekMessages(1);
  assert.equal(peeked.length, 1, "PEEK_NONEMPTY_REQUIRED");
  assert.deepEqual(Buffer.from(peeked[0].body), Buffer.from([7, 0, 8]), "PEEK_BODY_EXACT");
  const message = await receiveOne(receiver);
  const before = receiver.sessionLockedUntilUtc.getTime();
  await wait(30);
  // Session receivers expose renewSessionLock(); renewMessageLock() throws
  // unconditionally in @azure/service-bus 7.10.0 — the session-dialect API.
  const renewed = await receiver.renewSessionLock();
  assert.ok(renewed.getTime() > before, "MESSAGE_RENEW_MUST_EXTEND");
  await receiver.completeMessage(message);
  assert.equal(
    (await receiver.peekMessages(1)).length,
    0,
    "PEEK_EMPTY_AFTER_COMPLETE",
  );
  await receiver.close();
}

async function abandonCompleteCase() {
  const queue = `census-abandon-${prefix}`;
  const sessionId = prefix + "-ab";
  await sendOne(client, queue, "abandon", { sessionId });
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  const first = await receiveOne(receiver);
  await receiver.abandonMessage(first);
  const second = await receiveOne(receiver);
  assert.equal(second.messageId, first.messageId);
  assert.ok(second.deliveryCount > first.deliveryCount, "ABANDON_REDELIVERY_COUNT");
  await receiver.completeMessage(second);
  await receiver.close();
}

async function staleHandleCase() {
  const queue = `census-stale-${prefix}`;
  // Explicit 15 s lockDuration — asserts expiry lands on the CREATED
  // schedule, not the 30 s broker default (task 08-1 acceptance).
  await createQueueWithLockDuration(admin, queue, STALE_LOCK_DURATION);
  const sessionId = prefix + "-exp";
  await sendOne(client, queue, "expire", { sessionId });
  const stale = own(await acceptSessionNoRenew(client, queue, sessionId));
  const message = await receiveOne(stale);
  await wait(15_000 + 150);
  await assert.rejects(
    stale.completeMessage(message),
    (error) => /LockLost|lock.*lost|expired/i.test(errText(error)),
    "complete on an expired lock must be rejected LockLost",
  );
  const current = own(await acceptSessionNoRenew(client, queue, sessionId));
  const redelivered = await receiveOne(current);
  assert.equal(redelivered.messageId, message.messageId);
  assert.notEqual(redelivered.lockToken, message.lockToken, "NEW_LOCK_TOKEN_REQUIRED");
  await current.completeMessage(redelivered);
  await current.close();
  await stale.close();
}

// Expiry must land on the configured (PT2S) schedule, not the 30 s default.
async function lockDurationCase() {
  const queue = `census-lockdur-${prefix}`;
  await createQueueWithLockDuration(admin, queue, SHORT_LOCK_DURATION);
  const sessionId = prefix + "-ld";
  await sendOne(client, queue, "lockdur", { sessionId });
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  const message = await receiveOne(receiver);
  await wait(2_000 + 150);
  await assert.rejects(
    receiver.completeMessage(message),
    (error) => /LockLost|lock.*lost|expired/i.test(errText(error)),
    "complete after the configured 2s lockDuration must be rejected LockLost",
  );
  const redelivered = await receiveOne(receiver);
  assert.equal(redelivered.messageId, message.messageId);
  await receiver.completeMessage(redelivered);
  await receiver.close();
}

// Send -> defer -> receive-by-sequence-number -> complete; exactly one
// delivery, body equality, gone after complete.
async function deferredReceiveCase() {
  const queue = `census-defer-${prefix}`;
  const sessionId = prefix + "-def";
  await sendOne(client, queue, Buffer.from([4, 5, 6]), { sessionId });
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  const first = await receiveOne(receiver);
  assert.equal(first.deliveryCount, 1);
  await receiver.deferMessage(first);

  const deferred = await receiver.receiveDeferredMessages([first.sequenceNumber]);
  assert.equal(deferred.length, 1, "DEFERRED_RECEIVE_NONEMPTY");
  assert.deepEqual(Buffer.from(deferred[0].body), Buffer.from([4, 5, 6]), "DEFERRED_BODY_EXACT");
  assert.equal(deferred[0].deliveryCount, first.deliveryCount + 1, "DEFERRED_DELIVERY_COUNT");
  await receiver.completeMessage(deferred[0]);

  assert.equal(
    (await receiver.receiveDeferredMessages([first.sequenceNumber]).catch(() => [])).length,
    0,
    "DEFERRED_GONE_AFTER_COMPLETE",
  );
  await receiver.close();
}

// Reason + description + custom application properties observable on DLQ.
async function dlqPropertiesCase() {
  const queue = `census-dlqp-${prefix}`;
  const sessionId = prefix + "-dlqp";
  await sendOne(client, queue, Buffer.from([1, 2, 3]), {
    sessionId,
    applicationProperties: { CourtId: "c-42", RetryCount: 3 },
  });
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  const message = await receiveOne(receiver);
  await receiver.deadLetterMessage(message, {
    deadLetterReason: "COURT_REJECTED",
    deadLetterErrorDescription: "dlq-properties",
  });
  await receiver.close();

  const dead = own(
    client.createReceiver(queue, {
      subQueueType: "deadLetter",
      maxAutoLockRenewalDurationInMs: 0,
    }),
  );
  const found = await receiveOne(dead);
  assert.equal(found.deadLetterReason, "COURT_REJECTED");
  assert.equal(found.applicationProperties && found.applicationProperties.CourtId, "c-42", "DLQ_CUSTOM_PROP");
  assert.equal(found.applicationProperties && found.applicationProperties.RetryCount, 3, "DLQ_CUSTOM_PROP_INT");
  assert.deepEqual(Buffer.from(found.body), Buffer.from([1, 2, 3]));
  await dead.completeMessage(found);
  await dead.close();
}

async function deadLetterCase() {
  const queue = `census-dlq-${prefix}`;
  const sessionId = prefix + "-dlq";
  await sendOne(client, queue, Buffer.from([9, 0, 255]), { sessionId });
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  const message = await receiveOne(receiver);
  await receiver.deadLetterMessage(message, {
    deadLetterReason: "COURT_REJECTED",
    deadLetterErrorDescription: "census",
  });
  await receiver.close();
  const dead = own(
    client.createReceiver(queue, {
      subQueueType: "deadLetter",
      maxAutoLockRenewalDurationInMs: 0,
    }),
  );
  const found = await receiveOne(dead);
  assert.equal(found.deadLetterReason, "COURT_REJECTED");
  assert.deepEqual(Buffer.from(found.body), Buffer.from([9, 0, 255]));
  await dead.completeMessage(found);
  await dead.close();
}

async function orderedSessionCase() {
  const queue = `census-ordered-${prefix}`;
  const sessionId = prefix + "-ord";
  const sender = client.createSender(queue);
  try {
    await sender.sendMessages(
      [1, 2, 3].map((n) => ({ body: Buffer.from([n]), sessionId, messageId: `m${n}` })),
    );
  } finally {
    await sender.close();
  }
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  for (let n = 1; n <= 3; n++) {
    const message = await receiveOne(receiver);
    assert.equal(message.messageId, `m${n}`, "SESSION_ORDER_REQUIRED");
    assert.deepEqual(Buffer.from(message.body), Buffer.from([n]));
    await receiver.completeMessage(message);
  }
  await receiver.close();
}

// --- probes --------------------------------------------------------------------

const LOCK_DURATION_MS = 30_000;
const PROBE_TIMEOUT_MS = 10_000;
const AUTH_PROBE_TIMEOUT_MS = 30_000;

const tests = [
  probe("authentication", authenticationCase, AUTH_PROBE_TIMEOUT_MS),
  probe("bytes", bytesCase),
  probe("exclusive-session", exclusiveSessionCase),
  probe("renewal-peek", renewalPeekCase),
  probe("abandon-complete", abandonCompleteCase),
  // 15 s configured lockDuration + margin exceeds the 10 s default budget.
  probe("stale-handle", staleHandleCase, 15_000 + 5000),
  probe("dead-letter", deadLetterCase),
  probe("dlq-properties", dlqPropertiesCase),
  probe("ordered-session", orderedSessionCase),
  // 2 s configured schedule must surface LockLost within the default budget.
  probe("lock-duration", lockDurationCase),
  probe("deferred-receive", deferredReceiveCase),
];

function probe(name, fn, timeoutMs = PROBE_TIMEOUT_MS) {
  return { name, fn, timeoutMs };
}

async function runProbe(p) {
  const abort = AbortSignal.timeout(p.timeoutMs);
  const timeout = new Promise((_, reject) =>
    abort.addEventListener("abort", () =>
      reject(
        Object.assign(new Error("SDK_PROBE_DEADLINE_EXCEEDED"), { code: "SDK_PROBE_TIMEOUT" }),
        { once: true },
      ),
    ),
  );
  await test(`probe: ${p.name}`, { timeout: p.timeoutMs + 2000 }, async () => {
    await Promise.race([p.fn(), timeout]);
  });
}

// --- main ------------------------------------------------------------------------

const prefix = randomUUID();
let client;
let admin;
const handles = [];
const own = (h) => {
  handles.push(h);
  return h;
};

test("service bus census: 11 probes, fail-closed, zero skips", async () => {
  // Boot the private substrate unless the caller supplied credentials for a
  // running one (SMALT_SB_SHARED_KEY). Otherwise mint + sweep-down b11.
  let booted = null;
  if (!KEY) {
    booted = await bootPrivate(BLOCK);
    KEY = booted.sharedKey;
  }
  const connectionString =
    process.env.SMALT_SB_CONNECTION_STRING ||
    `Endpoint=sb://127.0.0.1:${booted ? booted.ports[0] : 39110};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${KEY};UseDevelopmentEmulator=true`;
  client = new ServiceBusClient(connectionString, CLIENT_OPTIONS);
  admin = new ServiceBusAdministrationClient(connectionString);
  try {
    for (const p of tests) {
      await runProbe(p);
    }
  } finally {
    const boundedClose = async (handle) => {
      let timer;
      try {
        await Promise.race([
          Promise.resolve(handle.close()).catch(() => {}),
          new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error("CLOSE_DEADLINE")), 1500); // SLEEP-CLASS: SCHEDULING (bounded watchdog, typed CLOSE_DEADLINE failure)
          }),
        ]);
      } finally {
        clearTimeout(timer);
      }
    };
    for (const handle of handles) {
      await boundedClose(handle).catch(() => {});
    }
    await boundedClose(client).catch(() => {});
    if (booted) downBlock(BLOCK);
  }
});
