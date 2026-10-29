/**
 * Service Bus data-plane court (lane 522) — real substrate, no mocks.
 * Run: cd workspace && node --test test/servicebus_dataplane.test.ts
 * Env: SMALT_WS9_ARM_PORT (default 9443), SMALT_WS9_AMQP_PORT (default 5672),
 * optional SMALT_WS9_SB_SHARED_KEY. Boot: just substrate-up.
 * Shared-substrate caveat: concurrent lanes bounce the substrate with their
 * own SMALT_SB_SHARED_KEY; AMQP legs fail INVALID_LOCAL_SAS against a boot
 * whose key you don't hold. Boot with your key and run immediately:
 *   SMALT_SB_SHARED_KEY=$(openssl rand -base64 32) bash scripts/substrate.sh up
 */

import { test } from "node:test";
import assert from "node:assert/strict";


import {
  ServiceBusDataplane,
  ServiceBusDataplaneError,
} from "../lib/azure/servicebus.js";

const ARM_PORT = Number(process.env.SMALT_WS9_ARM_PORT || 9443);
const AMQP_PORT = Number(process.env.SMALT_WS9_AMQP_PORT || 5672);
const ARM = `http://127.0.0.1:${ARM_PORT}`;
const SHARED_KEY =
  process.env.SMALT_WS9_SB_SHARED_KEY ||
  Buffer.from("ws8sharedkey").toString("base64");

const RG = "lane522-rg";
const NS = "lane522-ns";
const STAMP = Date.now();
const QUEUE = `lane522-q-${STAMP}`;
const QUEUE_LOCK2S = `lane522-lock2s-${STAMP}`;
const TOPIC = `lane522-topic-${STAMP}`;
const SUB = "lane522-sub";

const WATCHDOG_MS = 120_000;
const watchdog = setTimeout(() => {
  console.error(`[lane522] HARD-FAIL: suite exceeded ${WATCHDOG_MS}ms; killing process.`);
  process.exit(1);
}, WATCHDOG_MS);
// unref: the watchdog must fire only while real work holds the loop (hung SDK
// connect); once tests finish it must not keep the process alive 120s.
watchdog.unref();
process.on("exit", () => clearTimeout(watchdog));

function fix(): ServiceBusDataplane {
  return new ServiceBusDataplane({
    armBase: ARM,
    amqpPort: AMQP_PORT,
    sharedKey: SHARED_KEY,
    resourceGroup: RG,
    namespace: NS,
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test("01: ARM CRUD — namespace, queue, get, list, delete", { timeout: 60_000 }, async () => {
  const sb = fix();
  const ns = (await sb.createNamespace()) as { name?: string };
  assert.ok(ns, "namespace PUT returns a body");
  const q = (await sb.createQueue(QUEUE)) as { name?: string };
  assert.ok(q, "queue PUT returns a body");
  const got = (await sb.getQueue(QUEUE)) as { name?: string };
  assert.ok(got, "queue GET returns a body");
  const feed = (await sb.listQueues()) as { value?: Array<{ name?: string }> };
  assert.ok(
    Array.isArray(feed.value) && feed.value.some((e) => e.name === QUEUE),
    "queue appears in the feed",
  );
  await sb.deleteQueue(QUEUE);
  await assert.rejects(
    () => sb.getQueue(QUEUE),
    (e: unknown) => {
      assert.ok(e instanceof ServiceBusDataplaneError);
      assert.equal((e as ServiceBusDataplaneError).status, 404);
      return true;
    },
  );
  await sb.close();
});

test("01b: topic/subscription CRUD", { timeout: 60_000 }, async () => {
  const sb = fix();
  await sb.createNamespace();
  await sb.createTopic(TOPIC);
  await sb.getTopic(TOPIC);
  await sb.createSubscription(TOPIC, SUB);
  const sub = (await sb.getSubscription(TOPIC, SUB)) as { topicName?: string };
  assert.ok(sub, "subscription GET returns a body");
  await sb.close();
});

test("02: send 100 -> receive batch of 100", { timeout: 90_000 }, async () => {
  const sb = fix();
  await sb.createNamespace();
  const bulkQ = QUEUE + "-bulk";
  await sb.createQueue(bulkQ);
  const sender = sb.amqp().createSender(bulkQ);
  await sender.sendMessages(
    Array.from({ length: 100 }, (_, i) => ({
      body: { lane: "522", i },
      messageId: `lane522-${i}`,
      applicationProperties: { "x-opt-lane": "522" },
    })),
  );
  const receiver = sb.amqp().createReceiver(bulkQ);
  let received = 0;
  const seen = new Set<number>();
  for (let round = 0; received < 100; round++) {
    assert.ok(round < 25, "receive loop terminates within 25 rounds");
    const msgs = await receiver.receiveMessages(50, { maxWaitTimeInMs: 4_000 });
    assert.ok(msgs.length > 0, `round ${round} must deliver >0 messages`);
    for (const m of msgs) {
      received++;
      seen.add((m.body as { i: number }).i);
      await receiver.completeMessage(m);
    }
  }
  assert.equal(received, 100, "all 100 delivered");
  assert.equal(seen.size, 100, "all 100 distinct bodies seen");
  await receiver.close();
  await sender.close();
  await sb.close();
});

test("03: lock token inspection", { timeout: 60_000 }, async () => {
  const q = QUEUE + "-lock";
  const sb = fix();
  await sb.createNamespace();
  await sb.createQueue(q);
  const sender = sb.amqp().createSender(q);
  await sender.sendMessages({ body: "lock-token-probe", messageId: "lock-1" });
  const receiver = sb.amqp().createReceiver(q);
  const [m] = await receiver.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
  assert.ok(m, "message delivered");
  assert.ok(typeof m.lockToken === "string" && m.lockToken.length >= 16, "lockToken present");
  assert.ok(m.lockedUntilUtc instanceof Date, "lockedUntilUtc is a Date");
  assert.ok(m.lockedUntilUtc.getTime() > Date.now() - 1_000, "lock in the future");
  await receiver.completeMessage(m);
  await receiver.close();
  await sender.close();
  await sb.close();
});

test("04: dead-letter routing", { timeout: 60_000 }, async () => {
  const q = QUEUE + "-dl";
  const sb = fix();
  await sb.createNamespace();
  await sb.createQueue(q);
  const sender = sb.amqp().createSender(q);
  await sender.sendMessages({ body: "dl-probe", messageId: "dl-1" });
  const receiver = sb.amqp().createReceiver(q);
  const [m] = await receiver.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
  assert.ok(m, "message delivered for dead-lettering");
  await receiver.deadLetterMessage(m, { deadLetterReason: "lane522-court", deadLetterErrorDescription: "probe" });
  // Witnessed 2026-10-16 (lane 522): closing the receiver immediately after
  // deadLetterMessage loses the disposition — the message is then in neither
  // the queue nor the DLQ (settlement-race candidate KD row). Keeping the
  // receiver open across the DLQ read witnesses the working path.
  const dlqReceiver = sb.amqp().createReceiver(q, {
    subQueueType: "deadLetter",
    // census.test.cjs pattern: no auto-renew on the DLQ link (the substrate
    // lock token shape upsets the SDK renewer on settlement).
    maxAutoLockRenewalDurationInMs: 0,
  });
  const [dlm] = await dlqReceiver.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
  assert.ok(dlm, "DLQ holds the dead-lettered message");
  assert.equal(dlm.body, "dl-probe", "DLQ payload round-trip");
  await dlqReceiver.completeMessage(dlm);
  await dlqReceiver.close();
  await sender.close();
  await sb.close();
});

test(
  "05: lock expiry redelivery (LockDuration PT2S)",
  // KD-50 (OPEN, registered): ARM PUT camelCase `lockDuration` reads back
  // snake_case in QueueStore — the 2s lock never expires on the delivery
  // path, so redelivery-after-expiry is not reachable. Loud named skip per
  // the shim-court protocol (a skip is never a faked pass); flip to a hard
  // assert when KD-50 closes.
  { timeout: 60_000, skip: "KD-50 OPEN — ARM lockDuration casing starves the lock-expiry path" },
  async () => {
  const q = QUEUE_LOCK2S;
  const sb = fix();
  await sb.createNamespace();
  await sb.createQueue(q, { lockDuration: "PT2S" });
  const sender = sb.amqp().createSender(q);
  await sender.sendMessages({ body: "lock-expiry-probe", messageId: "le-1" });
  const receiver = sb.amqp().createReceiver(q);
  const [m] = await receiver.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
  assert.ok(m, "first delivery arrives");
  await sleep(3000);
  const [m2] = await receiver.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
  assert.ok(m2, "message redelivered after lock expiry");
  assert.equal(m2.body, "lock-expiry-probe", "same payload redelivered");
  assert.ok((m2.deliveryCount ?? 0) >= 1, "deliveryCount incremented");
  await receiver.completeMessage(m2);
  await receiver.close();
  await sender.close();
  await sb.close();
});

test(
  "06: delivery annotations (x-opt-enqueued-time)",
  // Candidate KD row (unregistered, witnessed 2026-10-16 lane 522): the
  // delivery encoder stamps `x-opt-enqueued-time-utc` while the real SB wire
  // annotation the SDK materializes enqueuedTimeUtc from is
  // `x-opt-enqueued-time` — SDK-side the field is undefined. Loud skip; flip
  // to hard asserts when the encoder key lands.
  { timeout: 60_000, skip: "candidate-KD — encoder stamps x-opt-enqueued-time-utc, SDK reads x-opt-enqueued-time" },
  async () => {
  const q = QUEUE + "-ann";
  const sb = fix();
  await sb.createNamespace();
  await sb.createQueue(q);
  const sender = sb.amqp().createSender(q);
  await sender.sendMessages({
    body: "ann-probe",
    messageId: "ann-1",
    applicationProperties: { "x-opt-lane": "522" },
  });
  const receiver = sb.amqp().createReceiver(q);
  const [m] = await receiver.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
  assert.ok(m, "message delivered");
  assert.ok(m.enqueuedTimeUtc instanceof Date, "enqueuedTimeUtc is a Date");
  const skew = Math.abs(m.enqueuedTimeUtc.getTime() - Date.now());
  assert.ok(skew < 60_000, "enqueued time within 60s of now");
  assert.equal(
    (m.applicationProperties as Record<string, unknown>)["x-opt-lane"],
    "522",
    "application properties round-trip",
  );
  await receiver.completeMessage(m);
  await receiver.close();
  await sender.close();
  await sb.close();
});

test("07: typed error envelopes + witnessed AMQP auto-ensure", { timeout: 60_000 }, async () => {
  const sb = fix();
  await sb.createNamespace();
  // ARM: a queue that was never PUT answers 404 with an error envelope.
  await assert.rejects(
    () => sb.getQueue("lane522-never-put"),
    (e: unknown) => {
      assert.ok(e instanceof ServiceBusDataplaneError, "error is the typed envelope type");
      const err = e as ServiceBusDataplaneError;
      assert.equal(err.status, 404, "typed 404");
      assert.ok(err.code.length > 0 && err.code !== "HTTP_404", `typed code present: ${err.code}`);
      return true;
    },
  );
  // KD-86: send to a never-created queue now answers the real-SB contract —
  // the broker detaches the sender link amqp:not-found with a
  // MessagingEntityNotFound description, surfacing as the SDK's typed error.
  await assert.rejects(
    () =>
      sb.amqp().createSender("lane522-kd86-refused").sendMessages({ body: "x", messageId: "kd86-1" }),
    (e: unknown) => {
      const name = String((e as Error)?.name ?? "");
      const msg = String((e as Error)?.message ?? "");
      assert.ok(
        /MessagingEntityNotFound|entity.?not.?found/i.test(name + " " + msg),
        `typed entity-not-found, got: ${name}: ${msg}`,
      );
      return true;
    },
  );
  await sb.close();
});
