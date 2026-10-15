// Service Bus SDK census (lane 15) — 8 probes, fail-closed, zero skips.
// Ported from the reference servicebus-local court script (upstream
// reference). Real SDK (@azure/service-bus) over real loopback AMQP against
// the smalt substrate booted by census-run.mjs. If the broker cannot satisfy
// a probe, the test FAILS — that is the correct fail-closed output at this
// stage.
"use strict";

const assert = require("node:assert/strict");
const { createRequire } = require("node:module");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const test = require("node:test").test;

const SDK_ROOT =
  process.env.SMALT_SDK_ROOT || (function(){ console.error("[sdk-smoke] set SMALT_SDK_ROOT to a node_modules dir containing @azure packages"); process.exit(3); })();
const sdkRequire = createRequire(path.join(SDK_ROOT, "package.json"));
const { ServiceBusClient } = sdkRequire("@azure/service-bus");

// The broker clamps every lock to 100–30000 ms with a 30000 ms default and
// never takes a caller-supplied lock duration on delivery
// (Smalt.Amqp.QueueStore.dequeue_matching is called with [] in
// Smalt.Amqp.Connection.deliver_to_link), so the effective lock duration is
// 30000 ms. Probe 6 waits lockDurationMs+150, which cannot fit a 10s probe
// budget; that probe alone gets lockDurationMs+5000. Fail-closed either way.
const LOCK_DURATION_MS = 30_000;
const PROBE_TIMEOUT_MS = 10_000;
// The 401 path walks core-amqp's full retry ladder (8s operation timeout at
// maxRetries:0) plus CBS round-trips; a 10s budget aborts mid-retry and reads
// as a false timeout instead of a real verdict. Auth alone gets 30s.
const AUTH_PROBE_TIMEOUT_MS = 30_000;

const KEY = process.env.SMALT_SB_SHARED_KEY;
if (!KEY || KEY.length < 32) {
  // census-run.mjs always provides the broker's shared key; a bare
  // `node --test` run refuses before any probe is registered.
  console.error(
    "[census.test.cjs] SMALT_SB_SHARED_KEY missing — run via census-run.mjs",
  );
  process.exit(1);
}
const CONNECTION_STRING =
  process.env.SMALT_SB_CONNECTION_STRING ||
  `Endpoint=sb://127.0.0.1:5672;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${KEY};UseDevelopmentEmulator=true`;

const CLIENT_OPTIONS = { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } };

// --- helpers -------------------------------------------------------------------

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const errText = (error) =>
  String(error && (error.code ?? error.name)) +
  " " +
  String(error && error.message);

async function receiveOne(receiver) {
  const messages = await receiver.receiveMessages(1, {
    maxWaitTimeInMs: 2000,
  });
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

// --- probe bodies ----------------------------------------------------------------

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
      (error) =>
        /Unauthorized|Authentication|unauthorized|authentication/i.test(
          errText(error),
        ),
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
  const receiver = own(
    client.createReceiver(queue, { maxAutoLockRenewalDurationInMs: 0 }),
  );
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
    (error) =>
      /SessionCannotBeLocked|SessionLock|session.*lock/i.test(errText(error)),
    "second accept on a locked session must be rejected SessionCannotBeLocked",
  );
  const before = receiver.sessionLockedUntilUtc.getTime();
  await wait(30);
  await receiver.renewSessionLock();
  assert.ok(
    receiver.sessionLockedUntilUtc.getTime() > before,
    "RENEWAL_MUST_EXTEND_LOCK",
  );
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
  // ServiceBusSessionReceiverImpl.renewMessageLock() throws unconditionally
  // (@azure/service-bus 7.10.0 sessionReceiver.js:431) — the session-dialect
  // API is renewSessionLock(). Against the pre-fix broker this probe died in
  // the SDK before reaching the wire, which masked the peek reply crash.
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
  const sessionId = prefix + "-exp";
  await sendOne(client, queue, "expire", { sessionId });
  const stale = own(await acceptSessionNoRenew(client, queue, sessionId));
  const message = await receiveOne(stale);
  await wait(LOCK_DURATION_MS + 150);
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

async function deadLetterCase() {
  const queue = `census-dlq-${prefix}`;
  const sessionId = prefix + "-dlq";
  await sendOne(client, queue, Buffer.from([9, 0, 255]), { sessionId });
  const receiver = own(await acceptSessionNoRenew(client, queue, sessionId));
  const message = await receiveOne(receiver);
  await receiver.deadLetterMessage(message, {
    deadLetterReason: "COURT_REJECTED",
    deadLetterErrorDescription: "local-test",
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

// --- probes ------------------------------------------------------------------

const tests = [
  probe("authentication", authenticationCase, AUTH_PROBE_TIMEOUT_MS),
  probe("bytes", bytesCase),
  probe("exclusive-session", exclusiveSessionCase),
  probe("renewal-peek", renewalPeekCase),
  probe("abandon-complete", abandonCompleteCase),
  // lockDurationMs+150 exceeds the 10s default budget; this probe alone gets
  // the full lock window plus margin.
  probe("stale-handle", staleHandleCase, LOCK_DURATION_MS + 5000),
  probe("dead-letter", deadLetterCase),
  probe("ordered-session", orderedSessionCase),
];

function probe(name, fn, timeoutMs = PROBE_TIMEOUT_MS) {
  return { name, fn, timeoutMs };
}

async function runProbe(p) {
  const abort = AbortSignal.timeout(p.timeoutMs);
  const timeout = new Promise((_, reject) =>
    abort.addEventListener("abort", () =>
      reject(
        Object.assign(new Error("SDK_PROBE_DEADLINE_EXCEEDED"), {
          code: "SDK_PROBE_TIMEOUT",
        }),
        { once: true },
      ),
    ),
  );
  await test(`probe: ${p.name}`, { timeout: p.timeoutMs + 2000 }, async () => {
    await Promise.race([p.fn(), timeout]);
  });
}

// --- main ----------------------------------------------------------------------

const prefix = randomUUID();
let client;
const handles = [];
const own = (h) => {
  handles.push(h);
  return h;
};

test("service bus census: 8 probes, fail-closed, zero skips", async () => {
  client = new ServiceBusClient(CONNECTION_STRING, CLIENT_OPTIONS);
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
            timer = setTimeout(() => reject(new Error("CLOSE_DEADLINE")), 1500);
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
  }
});
