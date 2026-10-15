// Event Hubs SDK smoke (lane 14) — real @azure/event-hubs 6.0.4 against the
// smalt AMQP 5673 wire lane, fail-closed, zero skips. Boot via eh-run.mjs.
// HONEST expectation (docs/WIRE_PARITY.md): the 5673 lane is PARTIAL —
// Smalt.Amqp.Connection never consults the listener mode flag, so an address
// containing `/eventhubs/` routes to QueueStore semantics, not
// Smalt.Messaging.EventHubs. These probes exist to witness that on the real
// wire: if EH semantics are absent, they FAIL here rather than silently pass.
"use strict";

const assert = require("node:assert/strict");
const { createRequire } = require("node:module");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const test = require("node:test").test;

const SDK_ROOT =
  process.env.SMALT_SDK_ROOT || (function(){ console.error("[sdk-smoke] set SMALT_SDK_ROOT"); process.exit(3); });
const sdkRequire = createRequire(path.join(SDK_ROOT, "package.json"));
const {
  EventHubProducerClient,
  EventHubConsumerClient,
} = sdkRequire("@azure/event-hubs");

const PROBE_TIMEOUT_MS = 15_000;
// eh-run.mjs pins the substrate's EH listener to this port (default substrate
// 5673 is the canonical lane port; the runner defaults to an alternate to
// avoid colliding with another lane's census substrate).
const EH_PORT = Number(process.env.SMALT_EH_PORT || 5673);

const KEY = process.env.SMALT_SB_SHARED_KEY;
if (!KEY || KEY.length < 32) {
  console.error(
    "[eventhubs.test.cjs] SMALT_SB_SHARED_KEY missing — run via eh-run.mjs",
  );
  process.exit(1);
}
const CONNECTION_STRING =
  process.env.SMALT_EH_CONNECTION_STRING ||
  `Endpoint=sb://127.0.0.1:${EH_PORT};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${KEY};EntityPath=smoke-hub;UseDevelopmentEmulator=true`;

const CLIENT_OPTIONS = { retryOptions: { maxRetries: 0, timeoutInMs: 10000 } };

// --- helpers -------------------------------------------------------------------

const errText = (error) =>
  String(error && (error.code ?? error.name)) +
  " " +
  String(error && error.message);

async function boundedClose(handle, ms = 3000) {
  let timer;
  try {
    await Promise.race([
      Promise.resolve(handle.close()).catch(() => {}),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("CLOSE_DEADLINE")), ms);
      }),
    ]);
  } catch {
    // close deadline: leave the socket to the process teardown
  } finally {
    clearTimeout(timer);
  }
}

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

// --- probe bodies ----------------------------------------------------------------

// Probe 1: management surface — getEventHubProperties must enumerate partitionIds.
async function getPropertiesCase(client) {
  const props = await client.getEventHubProperties({
    abortSignal: AbortSignal.timeout(12_000),
  });
  assert.ok(props, "PROPERTIES_REQUIRED");
  assert.ok(
    Array.isArray(props.partitionIds) && props.partitionIds.length > 0,
    "NONEMPTY_PARTITION_IDS_REQUIRED",
  );
  for (const id of props.partitionIds) {
    assert.equal(typeof id, "string", "PARTITION_ID_MUST_BE_STRING");
  }
  console.log(
    `[eventhubs.test.cjs] getProperties ok: partitionIds=${JSON.stringify(props.partitionIds)}`,
  );
}

// Probe 2: producer — createBatch + tryAdd + canAdd + send.
async function batchSendCase(client, hub) {
  const producer = new EventHubProducerClient(CONNECTION_STRING, hub, CLIENT_OPTIONS);
  try {
    const batch = await producer.createBatch({
      abortSignal: AbortSignal.timeout(12_000),
    });
    const sent = [];
    for (let i = 0; i < 3; i++) {
      const body = `batch-${prefix}-${i}`;
      assert.ok(batch.tryAdd({ body }), "TRYADD_MUST_SUCCEED");
      sent.push(body);
    }
    assert.equal(batch.count, 3, "BATCH_COUNT_MUST_BE_3");
    assert.equal(batch.canAdd(), true, "CANADD_AFTER_SMALL_BATCH");
    await producer.sendBatch(batch, {
      abortSignal: AbortSignal.timeout(12_000),
    });
    console.log(`[eventhubs.test.cjs] sendBatch ok: ${sent.length} events`);
  } finally {
    await boundedClose(producer);
  }
}

// Probe 3: consumer — subscribe from earliest on partition 0; received events
// must equal the ones sent to that partition, in send order. This is the
// discriminating probe for the documented 5673 wire gap: under QueueStore
// semantics partition routing/ordering is not EH, and this assert fires.
async function subscribeEarliestCase(consumerFactory, hub) {
  const producer = new EventHubProducerClient(CONNECTION_STRING, hub, CLIENT_OPTIONS);
  const consumer = consumerFactory();
  const subscriptionHandles = [];
  try {
    const props = await producer.getEventHubProperties({
      abortSignal: AbortSignal.timeout(12_000),
    });
    const partitionId = String(props.partitionIds[0]);

    const perPartition = new Map();
    const expected = new Map();
    for (const pid of props.partitionIds.map(String)) {
      perPartition.set(pid, []);
      expected.set(pid, pid === partitionId ? [] : null);
    }
    for (let i = 0; i < 3; i++) {
      const body = `ordered-${prefix}-${i}`;
      expected.get(partitionId).push(body);
      const batch = await producer.createBatch({ partitionId });
      assert.ok(batch.tryAdd({ body }), "TRYADD_ORDERED_MUST_SUCCEED");
      await producer.sendBatch(batch, {
        abortSignal: AbortSignal.timeout(12_000),
      });
    }

    // Subscribe every partition from earliest; only `partitionId` carries the
    // expected sequence, the rest must simply not swallow it.
    const done = { ref: null };
    for (const pid of props.partitionIds.map(String)) {
      const subscription = consumer.subscribe(
        pid,
        {
          processEvents: async (events) => {
            const bucket = perPartition.get(pid);
            for (const ev of events) {
              bucket.push(typeof ev.body === "string" ? ev.body : JSON.stringify(ev.body));
            }
            if (pid === partitionId && done.ref === null) {
              if (
                bucket.length >= expected.get(partitionId).length &&
                JSON.stringify(bucket.slice(0, expected.get(partitionId).length)) ===
                  JSON.stringify(expected.get(partitionId))
              ) {
                done.ref = true;
              }
            }
          },
          processError: async (err) => {
            console.error(`[subscribe:${pid}] processError:`, errText(err));
          },
        },
        { startPosition: { earliest: true }, maxWaitTimeInSeconds: 2 },
      );
      subscriptionHandles.push(subscription);
    }

    const deadline = Date.now() + 12_000;
    while (done.ref !== true) {
      if (Date.now() > deadline) {
        assert.fail(
          `ORDERED_RECEIVE_TIMEOUT: partition=${partitionId} received=${JSON.stringify(perPartition.get(partitionId))} expected=${JSON.stringify(expected.get(partitionId))}`,
        );
      }
      await new Promise((r) => setTimeout(r, 200));
    }

    const got = perPartition.get(partitionId);
    assert.deepEqual(
      got.slice(0, expected.get(partitionId).length),
      expected.get(partitionId),
      "PER_PARTITION_ORDER_REQUIRED",
    );
    console.log(
      `[eventhubs.test.cjs] subscribe ok: partition=${partitionId} received=${JSON.stringify(got)}`,
    );
  } finally {
    for (const s of subscriptionHandles) await boundedClose(s, 1500);
    await boundedClose(consumer);
    await boundedClose(producer);
  }
}

// --- main ----------------------------------------------------------------------

const prefix = randomUUID();

test("event hubs smoke: probes, fail-closed, zero skips", async () => {
  const client = new EventHubProducerClient(
    CONNECTION_STRING,
    "smoke-hub",
    CLIENT_OPTIONS,
  );
  try {
    for (const p of [
      probe("get-properties", () => getPropertiesCase(client)),
      probe("batch-send", () => batchSendCase(client, "smoke-hub")),
      probe("subscribe-earliest", () =>
        subscribeEarliestCase(
          () =>
            new EventHubConsumerClient(
              "$DEFAULT",
              CONNECTION_STRING,
              "smoke-hub",
              CLIENT_OPTIONS,
            ),
          "smoke-hub",
        ),
      ),
    ]) {
      await runProbe(p);
    }
  } finally {
    await boundedClose(client);
  }
});
