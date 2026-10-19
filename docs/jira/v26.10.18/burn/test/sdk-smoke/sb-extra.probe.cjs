// Supplementary Service Bus SDK probes (lane TS-4).
// Real @azure/service-bus 7.10.0 against the smalt substrate. Standalone:
//   SMALT_SDK_ROOT=... SMALT_SB_CONNECTION_STRING=... SMALT_SB_SHARED_KEY=... \
//     node test/sdk-smoke/sb-extra.probe.cjs
"use strict";
const path = require("node:path");
const SDK_ROOT = process.env.SMALT_SDK_ROOT;
if (!SDK_ROOT) { console.error("SMALT_SDK_ROOT not set"); process.exit(3); }
const azsb = require(path.join(SDK_ROOT, "@azure/service-bus"));

const connStr = process.env.SMALT_SB_CONNECTION_STRING;
if (!connStr || !process.env.SMALT_SB_SHARED_KEY) {
  console.error("SMALT_SB_CONNECTION_STRING / SMALT_SB_SHARED_KEY required");
  process.exit(3);
}

let pass = 0;
let fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + err.message); }
  else { pass++; console.log("PASS " + name); }
}

async function main() {
  const admin = new azsb.ServiceBusAdministrationClient(connStr);
  const queue = "ts4-extra";
  try { await admin.createQueue(queue, {}); } catch (e) { /* exists */ }

  const client = new azsb.ServiceBusClient(connStr, { retryOptions: { maxRetries: 0, timeoutInMs: 8000 } });
  const sender = client.createSender(queue);

  // 1. scheduleMessage
  try {
    const at = new Date(Date.now() + 2000);
    const sent = await sender.scheduleMessages([{ body: { kind: "ts4" }, messageId: "ts4-sched-1" }], at);
    const seq = sent[0];
    const rx = client.createReceiver(queue);
    const early = await rx.receiveMessages(10, { maxWaitTimeInMs: 1500 });
    let err = null;
    if (early.some(m => m.messageId === "ts4-sched-1")) {
      err = new Error("visible before ScheduledEnqueueTime");
    } else {
      await new Promise(r => setTimeout(r, 2500));
      const late = await rx.receiveMessages(10, { maxWaitTimeInMs: 3000 });
      if (!late.some(m => m.messageId === "timed-schedule-id")) {
        // accept either id check below; do the real check:
        if (!late.some(m => m.messageId === "ts4-sched-1")) {
          err = new Error("scheduled message never delivered after delay");
        }
      }
    }
    record("scheduleMessage", err);
  } catch (e) { record("scheduleMessage", e); }

  // 2. receiveAndDelete delivery
  try {
    await sender.sendMessages([{ body: { kind: "ts4" }, messageId: "ts4-fire-1" }]);
    const rx = client.createReceiver(queue, { receiveMode: "receiveAndDelete" });
    const msgs = await rx.receiveMessages(1, { maxWaitTimeInMs: 3000 });
    if (msgs.length === 0) throw new Error("no delivery");
    if (msgs[0].messageId !== "ts4-fire-1") throw new Error("wrong message " + msgs[0].messageId);
    record("receiveAndDelete-delivery", null);
  } catch (e) { record("receiveAndDelete-delivery", e); }

  // 3. acceptNextSession on sessionless queue: SDK throws after maxWaitTimeInMs.
  try {
    const sessRx = await client.acceptNextSession("ts4-extra", { maxWaitTimeInMs: 2000 });
    await sessRx.close();
    record("acceptNextSession-no-session", new Error("unexpected session accepted"));
  } catch (e) {
    if (e.message === "unexpected session accepted") throw e;
    record("acceptNextSession-no-session", null);
  }

  await client.close();
  console.log("SUMMARY pass=" + pass + " fail=" + fail);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch(function (e) { console.error("harness:", e); process.exit(1); });
