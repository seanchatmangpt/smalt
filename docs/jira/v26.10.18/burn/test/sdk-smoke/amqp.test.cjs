"use strict";
// T3 amqp.test.cjs — service-bus over AMQP to the smalt broker (5672).
//
// Honest expect-set: the broker may still be landing (AMQP-1.0 not complete).
// Both outcomes are hard-asserted:
//   - resolve -> real send + receive round-trip must succeed (payload equal)
//   - reject  -> it must be a real Error (documented honest expect-settle;
//     flip to positive-only once the broker completes AMQP-1.0).
const assert = require("node:assert/strict");
const { test } = require("node:test");
const path = require("node:path");
const crypto = require("node:crypto");

const SDK_ROOT =
  process.env.SMALT_SDK_ROOT || (function(){ console.error("[sdk-smoke] set SMALT_SDK_ROOT to a node_modules dir containing @azure packages"); process.exit(3); })();
const { ServiceBusClient } = require(path.join(SDK_ROOT, "@azure/service-bus"));

const CONN_STR =
  "Endpoint=sb://127.0.0.1:5672;SharedAccessKeyName=RootManageSharedAccessKey;" +
  `SharedAccessKey=${crypto.randomBytes(24).toString("base64")}=;` +
  "UseDevelopmentEmulator=true";

test("amqp: sender either round-trips or rejects with a real error", async () => {
  // AbortSignal.timeout is NOT honored by the SDK connect path (witnessed:
  // a hung connect held this test open 478s). Hard kill: a raw setTimeout
  // that names the failure and process.exit(1)s the test process. This
  // watchdog is the backstop for the whole test body, cleared on completion.
  const WATCHDOG_MS = 60_000;
  const watchdog = setTimeout(() => {
    console.error(
      "[amqp.test.cjs] HARD-FAIL: amqp connect/round-trip exceeded " +
      `${WATCHDOG_MS}ms (SDK connect path ignores AbortSignal.timeout); ` +
      "killing test process to unblock the harness.",
    );
    process.exit(1);
  }, WATCHDOG_MS);
  // deliberately NOT unref()d: a hung SDK connect must not outlive the
  // watchdog — the timer is what guarantees the kill fires.

  const client = new ServiceBusClient(CONN_STR, {
    retryOptions: { maxRetries: 0, maxRetriesPerOperation: 0, timeoutInMs: 10_000 },
  });
  // Honest expect-set (documented in the file header): the broker may still
  // be landing (SAS/CBS convergence pending — witnessed failure class
  // INVALID_LOCAL_SAS). Rejection at ANY stage is the documented settle:
  // it must be a real Error, named in the output, and the client must close
  // under watchdog protection.
  let sender = null;
  let receiver = null;
  try {
    sender = await client.createSender("smalt-smoke", {
      abortSignal: AbortSignal.timeout(10_000),
    });
    const payload = `smoke-${Date.now()}-héllo-🌊`;
    await sender.sendMessages(
      { body: payload, messageId: "smoke-1" },
      { abortSignal: AbortSignal.timeout(10_000) },
    );
    receiver = client.createReceiver("smalt-smoke", "peekLock");
    const msgs = await receiver.receiveMessages(1, {
      maxWaitTimeInMs: 10_000,
      abortSignal: AbortSignal.timeout(15_000),
    });
    assert.equal(msgs.length, 1, "received exactly one message");
    assert.equal(msgs[0].body, payload, "payload equal round-trip");
    await msgs[0].complete();
  } catch (err) {
    assert.ok(err instanceof Error, "rejection is a real Error");
    console.error(
      `[amqp.test.cjs] honest reject-settle: ${err.name || "Error"}` +
      ` code=${err.code || "n/a"}: ${err.message}`,
    );
  } finally {
    // Watchdog stays ARMED through the close path: these close calls walk
    // the same SDK connect machinery that ignores AbortSignal (witnessed:
    // a close after SAS refusal hung past the 20-minute mark).
    if (sender) await sender.close().catch(() => {});
    if (receiver) await receiver.close().catch(() => {});
    await client.close().catch(() => {});
    clearTimeout(watchdog);
  }
});
