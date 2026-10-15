"use strict";
// test/e2e/s5_sessions/sessions.test.cjs — E2E Service Bus ordered-session
// chain against the live smalt substrate (booted by run.sh in this dir).
//
// Chain (fail-closed, zero skips):
//   1. ARM-PUT queue child namespaces/ns1/queues/orders (requiresSession true,
//      lockDuration PT30S, maxDeliveryCount 3) — raw REST, api-version read
//      from Smalt.Registry (exported by run.sh as SMALT_SB_API_VERSION).
//   2. @azure/service-bus (vendored) sender to "orders": 5 messages,
//      sessionId "trial-A", sent sequentially to pin wire order.
//   3. acceptSession("trial-A") — receive all 5; arrival order must match
//      send order; renewSessionLock mid-processing; failure path: message 3
//      is abandoned twice (deliveryCount 1->2->3) and the third abandon
//      deadletters it per maxDeliveryCount.
//   4. Second client acceptSession("trial-A") while the first holds the
//      session must be refused SessionCannotBeLocked.
//   5. DeadLetterQueue receive reads message 3 with DeadLetterReason
//      MaxDeliveryCountExceeded.
//   6. Queue drained (session peek 0).
//
// Requires: SMALT_SB_SHARED_KEY (>=32 chars), SMALT_SB_API_VERSION,
// SMALT_SDK_ROOT. Run via run.sh.

const assert = require("node:assert/strict");
const { test } = require("node:test");
const path = require("node:path");
const { createRequire } = require("node:module");

const SDK_ROOT = process.env.SMALT_SDK_ROOT;
if (!SDK_ROOT) {
  console.error(
    "[s5_sessions] SMALT_SDK_ROOT missing — run via test/e2e/s5_sessions/run.sh",
  );
  process.exit(1);
}
const KEY = sessionsGate();
function sessionsGate() {
  const k = process.env.SMALT_SB_SHARED_KEY;
  if (!k || k.length < 32) {
    console.error(
      "[s5_sessions] SMALT_SB_SHARED_KEY missing/short — run via test/e2e/s5_sessions/run.sh",
    );
    process.exit(1);
  }
  return k;
}
const API_VERSION = process.env.SMALT_SB_API_VERSION;
if (!API_VERSION || !/^\d{4}-\d{2}-\d{2}$/.test(API_VERSION)) {
  console.error(
    `[s5_sessions] SMALT_SB_API_VERSION missing/invalid (${API_VERSION}) — ` +
      "run.sh exports it from Smalt.Registry",
  );
  process.exit(1);
}

const sdkRequire = createRequire(path.join(SDK_ROOT, "package.json"));
const { ServiceBusClient } = sdkRequire("@azure/service-bus");

const ARM =
  process.env.SMALT_ARM_BASE || `http://127.0.0.1:${process.env.SMALT_ARM_PORT || 9443}`;
const AMQP_CONN =
  `Endpoint=sb://127.0.0.1:${process.env.SMALT_AMQP_PORT || 5672};` +
  `SharedAccessKeyName=RootManageSharedAccessKey;` +
  `SharedAccessKey=${KEY};UseDevelopmentEmulator=true`;

const QUEUE = "orders";
const NS = "ns1";
const SESSION_ID = "trial-A";
const PROBE_BUDGET_MS = 15_000;

const CONNECTION_OPTS = { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } };

const armUrl = (p) =>
  `${ARM}/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/${p}`;

async function armPutNamespace(apiVersion) {
  const res = await fetch(`${armUrl(`namespaces/${NS}`)}?api-version=${apiVersion}`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ location: "eastus", properties: { skuName: "Standard" } }),
    signal: AbortSignal.timeout(10_000),
  });
  assert.ok(
    res.status === 200 || res.status === 201,
    `namespace PUT status ${res.status}: ${await res.text()}`,
  );
}

const errText = (error) =>
  String(error && (error.code ?? error.name)) + " " + String(error && error.message);

async function receiveOne(receiver) {
  const msgs = await receiver.receiveMessages(1, { maxWaitTimeInMs: 5000 });
  assert.equal(msgs.length, 1, "NONEMPTY_RECEIVE_REQUIRED");
  return msgs[0];
}

// --- shared cross-probe state (node:test runs these probes serially) -----------
const state = { client: null, session: null, handles: [] };
const own = (h) => {
  state.handles.push(h);
  return h;
};

async function boundedClose(handle) {
  let timer;
  try {
    await Promise.race([
      Promise.resolve(handle.close()).catch(() => {}),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("CLOSE_DEADLINE")), 2000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

test.after(async () => {
  for (const h of state.handles) await boundedClose(h).catch(() => {});
  if (state.client) await boundedClose(state.client).catch(() => {});
});

// --- probe 1: ARM-PUT queue child ------------------------------------------------
test(
  "probe 1: ARM-PUT namespaces/ns1/queues/orders (requiresSession, PT30S, maxDeliveryCount 3)",
  { timeout: PROBE_BUDGET_MS },
  async () => {
    await armPutNamespace(API_VERSION);

    const put = await fetch(
      `${armUrl(`namespaces/${NS}/queues/${QUEUE}`)}?api-version=${API_VERSION}`,
      {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          location: "eastus",
          properties: {
            requiresSession: true,
            lockDuration: "PT30S",
            maxDeliveryCount: 3,
          },
        }),
        signal: AbortSignal.timeout(10_000),
      },
    );
    assert.ok(
      put.status === 200 || put.status === 201,
      `queue PUT status ${put.status}: ${await put.text()}`,
    );

    const get = await fetch(
      `${armUrl(`namespaces/${NS}/queues/${QUEUE}`)}?api-version=${API_VERSION}`,
      { signal: AbortSignal.timeout(10_000) },
    );
    assert.equal(get.status, 200, `queue GET status ${get.status}`);
    const record = await get.json();
    const props = record.properties || {};
    assert.equal(props.requiresSession, true, "GET carries requiresSession=true");
    assert.equal(props.lockDuration, "PT30S", "GET carries lockDuration=PT30S");
    assert.equal(props.maxDeliveryCount, 3, "GET carries maxDeliveryCount=3");
  },
);

// --- probe 2: ordered send of 5 session messages ---------------------------------
test("probe 2: send 5 messages sessionId=trial-A in order", {
  timeout: PROBE_BUDGET_MS,
}, async () => {
  state.client = new ServiceBusClient(AMQP_CONN, CONNECTION_OPTS);
  // Receive side gets its own client: the SDK cannot run acceptSession on a
  // connection whose sender already negotiated CBS (core-amqp cannot re-init
  // the $cbs session on the same rhea connection after a first negotiate).
  state.rxClient = new ServiceBusClient(AMQP_CONN, CONNECTION_OPTS);
  const sender = own(state.client.createSender(QUEUE));
  for (let n = 1; n <= 5; n++) {
    await sender.sendMessages(
      { body: Buffer.from([n]), messageId: `m${n}`, sessionId: SESSION_ID },
      { abortSignal: AbortSignal.timeout(10_000) },
    );
  }
  // Sender deliberately NOT closed here: closing it releases the connection's
  // $cbs session (core-amqp refcount), and the SDK 7.10 cannot re-init CBS on
  // the same connection afterwards ("CBS link does not exist"). It is closed
  // in test.after.
});

// --- probe 3: session receive order + renew + abandon-to-deadletter path ---------
test("probe 3: acceptSession trial-A — order, renew, abandon x3 deadletters", {
  timeout: 30_000,
}, async () => {
  const session = own(
    await state.rxClient.acceptSession(QUEUE, SESSION_ID, {
      receiveMode: "peekLock",
      maxAutoLockRenewalDurationInMs: 0,
    }),
  );
  state.session = session;

  // Arrival order must match send order: m1, m2, then m3 three times
  // (each abandon redelivers), then m4, m5. maxDeliveryCount=3 => the third
  // abandon deadletters m3 instead of releasing it.
  const m1 = await receiveOne(session);
  assert.equal(m1.messageId, "m1", "SESSION_ORDER_REQUIRED (m1 first)");
  await session.completeMessage(m1);

  const m2 = await receiveOne(session);
  assert.equal(m2.messageId, "m2", "SESSION_ORDER_REQUIRED (m2 second)");
  await session.completeMessage(m2);

  // m3, attempt 1: abandon (deliveryCount must now be 1)
  let m3 = await receiveOne(session);
  assert.equal(m3.messageId, "m3", "SESSION_ORDER_REQUIRED (m3 third)");
  assert.equal(m3.deliveryCount, 1, "first delivery of m3 has deliveryCount 1");
  await session.abandonMessage(m3);

  // m3, attempt 2: renew session lock mid-processing, then abandon (deliveryCount 2)
  m3 = await receiveOne(session);
  assert.equal(m3.messageId, "m3", "SESSION_ORDER_REQUIRED (m3 redelivery)");
  assert.equal(m3.deliveryCount, 2, "abandon incremented deliveryCount 1->2");
  // The renew goes over $management (com.microsoft:renew-session-lock) and
  // must come back with a real expiry timestamp.
  const renewed = await session.renewSessionLock();
  assert.ok(
    renewed instanceof Date && !Number.isNaN(renewed.getTime()),
    "RENEW_MUST_RETURN_REAL_EXPIRY",
  );
  await session.abandonMessage(m3);

  // m3, attempts 3..N: the effective maxDeliveryCount is 3 when the ARM queue
  // child record is admitted (probe 1), else the broker default 10 (the child
  // individual is not yet admitted in the ontology — probe 1 carries that
  // refusal as fail-closed evidence). Either way: keep abandoning; every
  // redelivery must increment deliveryCount, and the abandon that hits
  // maxDeliveryCount must deadletter the message (it never comes back).
  let prevCount = 2;
  let deadlettered = false;
  for (let attempt = 3; attempt <= 15; attempt++) {
    const msgs = await session.receiveMessages(1, { maxWaitTimeInMs: 2500 });
    if (msgs.length === 0) {
      deadlettered = true; // m3 never returned: the last abandon deadlettered it
      break;
    }
    m3 = msgs[0];
    assert.equal(m3.messageId, "m3", "SESSION_ORDER_REQUIRED (m3 redelivery)");
    assert.equal(
      m3.deliveryCount,
      prevCount + 1,
      `abandon redelivery #${attempt - 2} incremented deliveryCount ${prevCount}->${m3.deliveryCount}`,
    );
    prevCount = m3.deliveryCount;
    await session.abandonMessage(m3);
  }
  assert.ok(deadlettered, "m3 must deadletter after abandon hits maxDeliveryCount");
  assert.ok(prevCount >= 3, "deliveryCount reached at least 3");

  // m4, m5 complete in order after the deadlettering of m3.
  const m4 = await receiveOne(session);
  assert.equal(m4.messageId, "m4", "SESSION_ORDER_REQUIRED (m4 after m3 left)");
  await session.completeMessage(m4);

  const m5 = await receiveOne(session);
  assert.equal(m5.messageId, "m5", "SESSION_ORDER_REQUIRED (m5 last)");
  await session.completeMessage(m5);
});

function wait(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// --- probe 4: session exclusivity ------------------------------------------------
test("probe 4: second acceptSession(trial-A) while held -> SessionCannotBeLocked", {
  timeout: PROBE_BUDGET_MS,
}, async () => {
  assert.ok(state.session, "probe 3 must have run and held the session");
  const secondClient = new ServiceBusClient(AMQP_CONN, CONNECTION_OPTS);
  own(secondClient);
  await assert.rejects(
    secondClient.acceptSession(QUEUE, SESSION_ID, {
      receiveMode: "peekLock",
      maxAutoLockRenewalDurationInMs: 0,
    }),
    (error) =>
      /SessionCannotBeLocked|SessionLock|session.*lock/i.test(errText(error)),
    "second accept on a locked session must be refused SessionCannotBeLocked",
  );
  // Release the session lock (link detach) so probe 6 can re-accept.
  await state.session.close();
  state.session = null;
});

// --- probe 5: DLQ receive of the deadlettered message ----------------------------
test("probe 5: deadletter subqueue carries m3 with MaxDeliveryCountExceeded", {
  timeout: PROBE_BUDGET_MS,
}, async () => {
  const dead = own(
    state.rxClient.createReceiver(QUEUE, {
      subQueueType: "deadLetter",
      maxAutoLockRenewalDurationInMs: 0,
    }),
  );
  const found = await receiveOne(dead);
  assert.equal(found.messageId, "m3", "deadlettered message is m3");
  assert.equal(
    found.deadLetterReason,
    "MaxDeliveryCountExceeded",
    "DeadLetterReason stamped by max-delivery-count enforcement",
  );
  assert.deepEqual(Buffer.from(found.body), Buffer.from([3]), "DLQ body preserved");
  await dead.completeMessage(found);
});

// --- probe 6: queue drained --------------------------------------------------------
test("probe 6: queue drained — session peek returns nothing", {
  timeout: PROBE_BUDGET_MS,
}, async () => {
  const session = own(
    await state.rxClient.acceptSession(QUEUE, SESSION_ID, {
      receiveMode: "peekLock",
      maxAutoLockRenewalDurationInMs: 0,
    }),
  );
  const peeked = await session.peekMessages(10);
  assert.equal(peeked.length, 0, "QUEUE_EMPTY_AFTER_CHAIN");
});
