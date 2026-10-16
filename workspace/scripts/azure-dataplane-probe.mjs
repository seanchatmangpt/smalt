#!/usr/bin/env node
// azure-dataplane-probe.mjs — WS-9 lane probe: runs the four pure-Azure
// data-plane client modules (workspace/lib/azure/*.ts) against a LIVE smalt
// substrate. Boot is owned by the caller (flock /tmp/smalt-substrate.lock);
// if a substrate is already live on the canonical ports this probe reuses
// it read-only with lane-unique names (ws9-* prefixes / Date.now() suffixes).
//
// Env:
//   NEXT_PUBLIC_SMALT_EGRESS   (default http://127.0.0.1:8443)
//   SMALT_WS9_AMQP_PORT        (default 5672)
//   SMALT_WS9_EH_PORT          (default 5673)
//   SMALT_WS9_ARM_PORT         (default 9443)
//   SMALT_WS9_SB_SHARED_KEY    (required — broker SAS verifier seeded at boot)
//
// Every row prints a LIVE witness line: what ran, with what exact output.
// Divergence from expected Azure semantics is recorded, never fixed here
// (lib/ fixes are another lane's ownership).
import { createRequire } from "node:module";

const require = createRequire(new URL("../package.json", import.meta.url));
const { BlobServiceClient, StorageSharedKeyCredential } = require("@azure/storage-blob");
const { CosmosClient } = require("@azure/cosmos");
const { ServiceBusClient } = require("@azure/service-bus");
const {
  EventHubProducerClient,
  EventHubConsumerClient,
} = require("@azure/event-hubs");

const blob = await import("../lib/azure/blob-export.ts");
const sb = await import("../lib/azure/sb-telemetry.ts");
const cosmos = await import("../lib/azure/cosmos-manifest.ts");
const eh = await import("../lib/azure/eh-stream.ts");

const EGRESS = process.env.NEXT_PUBLIC_SMALT_EGRESS || "http://127.0.0.1:8443";
const AMQP_PORT = Number(process.env.SMALT_WS9_AMQP_PORT || 5672);
const EH_PORT = Number(process.env.SMALT_WS9_EH_PORT || 5673);
const ARM = `http://127.0.0.1:${Number(process.env.SMALT_WS9_ARM_PORT || 9443)}`;
const SB_KEY = process.env.SMALT_WS9_SB_SHARED_KEY;
if (!SB_KEY) {
  console.error("[ws9] SMALT_WS9_SB_SHARED_KEY missing — run under the boot wrapper");
  process.exit(3);
}

const T = (ms) => AbortSignal.timeout(ms);
const close = (h) => h?.close?.().catch?.(() => {});
let failures = 0;
const run = (name, fn) => fn().then(
  (r) => { console.log(`[ws9] PASS ${name}`, JSON.stringify(r)); return true; },
  (e) => { console.log(`[ws9] FAIL ${name}:`, e?.message ?? e); failures++; return false; },
);

// ---------------------------------------------------------------------------
// 1. Blob — WORM receipt export
// ---------------------------------------------------------------------------
{
  const sessionId = `ws9-${Date.now()}`;
  const service = new BlobServiceClient(
    `${EGRESS}/smaltacct`,
    new StorageSharedKeyCredential(blob.BLOB_ACCOUNT, blob.BLOB_ACCOUNT_KEY),
  );
  const bundle = {
    sessionId,
    receipts: [
      { seq: 1, actor: "ws9-probe", claim: "ledger sealed", at: new Date().toISOString() },
      { seq: 2, actor: "ws9-probe", claim: "héllo 🌊 multibyte", at: new Date().toISOString() },
    ],
    metadata: { lane: "ws9" },
  };
  await run("blob/exportReceiptBundle", async () => {
    const res = await blob.exportReceiptBundle(service, bundle);
    if (!res.overwriteRejected) throw new Error("WORM 409 not witnessed");
    // read-back: exported bytes are durable
    const dl = await service
      .getContainerClient(res.containerName)
      .getBlobClient(res.bundleBlobName)
      .downloadToBuffer(undefined, undefined, { abortSignal: T(30_000) });
    const parsed = JSON.parse(dl.toString("utf8"));
    if (parsed[1]?.claim !== bundle.receipts[1].claim) {
      throw new Error("read-back mismatch");
    }
    return { ...res, readBack: "equal", bytes: dl.length };
  });

  // negative control inside an immutable container is covered above; the
  // mutable-container contract (x-ms-immutable-policy: false) is a substrate
  // extension outside this lane's lib surface.
}

// ---------------------------------------------------------------------------
// 2. Cosmos — mission manifests (SELECT * FROM c only)
// ---------------------------------------------------------------------------
{
  const dbId = `ws9-db-${Date.now()}`;
  const collId = "ws9-manifests";
  const client = new CosmosClient({
    endpoint: EGRESS,
    key: require("node:crypto").randomBytes(32).toString("hex"),
    retryOptions: { maxRetryAttemptCount: 0 },
    connectionPolicy: { enableEndpointsDiscovery: false },
  });
  // NOTE (witnessed on this substrate): PUT /dbs/:db → 400, but the
  // container create route (POST /dbs/:db/colls) is mounted and the docs
  // engine is permissive about the parent db entity — provision via the
  // SDK createIfNotExists paths, tolerate the db-route refusal.
  const store = await cosmos.createManifestStore(client, dbId, collId)
    .catch((e) => { console.log(`[ws9] cosmos store provision: ${e.message}`); return null; });
  if (!store) failures++;
  const container = client.database(dbId).container(collId);
  const manifests = [
    { id: "m-1", pk: "alpha", mission: "orbital-1", payload: { crew: 4 }, revision: 1 },
    { id: "m-2", pk: "beta", mission: "orbital-2", payload: { crew: 2 }, revision: 3 },
  ];
  await run("cosmos/upsertManifest x2", async () => {
    const statuses = [];
    for (const m of manifests) statuses.push(await cosmos.upsertManifest(container, m));
    if (!statuses.every((s) => [200, 201].includes(s))) {
      throw new Error(`upsert statuses ${statuses}`);
    }
    return { statuses };
  });

  await run("cosmos/readManifests (SELECT * FROM c)", async () => {
    const read = await cosmos.readManifests(container, { pk: "alpha" });
    if (read.length !== 1 || read[0].mission !== "orbital-1") {
      throw new Error(`query returned ${JSON.stringify(read).slice(0, 200)}`);
    }
    return { query: cosmos.MANIFEST_QUERY, matched: read.length, of: 2 };
  });
}

// ---------------------------------------------------------------------------
// 3. Service Bus — telemetry send / receive / complete + session probe
// ---------------------------------------------------------------------------
{
  const plainQueue = `ws9-plain-${Date.now()}`;
  const sessionQueue = `ws9-sessions-${Date.now()}`;
  const conn = sb.sbConnectionString(AMQP_PORT, SB_KEY);
  const client = new ServiceBusClient(conn, {
    retryOptions: { maxRetries: 0, timeoutInMs: 10_000 },
  });

  await run(`sb/ensureQueue ${plainQueue}`, async () => ({
    status: await sb.ensureQueue(ARM, plainQueue),
  }));

  await run(`sb/ensureQueue(session) ${sessionQueue}`, async () => ({
    status: await sb.ensureQueue(ARM, sessionQueue, { requiresSession: true, lockDuration: "PT30S" }),
  }));

  const sender = await client.createSender(plainQueue, { abortSignal: T(20_000) });
  const event = {
    missionId: "ws9-mission-1",
    kind: "probe",
    detail: `telemetry-${Date.now()}-🌊`,
    at: new Date().toISOString(),
  };
  await run("sb/sendTelemetry", async () => {
    await sb.sendTelemetry(sender, event);
    return { sent: event.detail };
  });

  const receiver = client.createReceiver(plainQueue, "peekLock");
  const rx = await run("sb/receiveAndComplete", async () => {
    const res = await sb.receiveAndComplete(receiver, 1);
    if (res.received === 0) {
      throw new Error(
        "no delivery on receiver-link flow credit (known WIRE_PARITY limitation: " +
        "Smalt.Amqp.Connection deliver path never dequeues) — send-side witnessed only",
      );
    }
    if (res.messages[0].body?.detail !== event.detail) throw new Error("payload mismatch");
    return res;
  });
  if (!rx) console.log("[ws9] DIVERGENCE sb: send resolved but receive produced no delivery (documented substrate limitation, not fixed in this lane)");
  await close(receiver);

  await run("sb/session probe", async () => {
    const sSender = await client.createSender(sessionQueue, { abortSignal: T(20_000) });
    try {
      await sSender.sendMessages(
        { body: "session-payload", sessionId: "S1", messageId: "ws9-s1" },
        { abortSignal: T(20_000) },
      );
    } finally {
      await close(sSender);
    }
    const sessionReceiver = await Promise.race([
      client.acceptSession(sessionQueue, "S1", { abortSignal: T(12_000) }),
      new Promise((_, rej) => setTimeout(() => rej(new Error("acceptSession deadline 12s")), 12_000)),
    ]);
    try {
      const msgs = await sessionReceiver.receiveMessages(1, {
        maxWaitTimeInMs: 6_000,
        abortSignal: T(12_000),
      });
      if (msgs.length === 0) {
        throw new Error("session link attached but no delivery (same deliver-path limitation)");
      }
      const m = msgs[0];
      const raw = typeof m?.complete !== "function";
      if (String(m.body) !== "session-payload") throw new Error(`payload mismatch: ${JSON.stringify(m.body)}`);
      if (m.sessionId !== "S1") throw new Error(`sessionId not preserved: ${m.sessionId}`);
      return {
        received: 1, body: m.body, sessionId: m.sessionId,
        settlement: raw
          ? "NOT witnessed — delivered entry is a RAW undecorated AMQP message (no SDK complete(); substrate returns the rhea transport message, not ServiceBusReceivedMessageWithLocker)"
          : "complete() witnessed",
      };
    } finally {
      await close(sessionReceiver);
    }
  });

  await close(sender);
  await close(client);
}

// ---------------------------------------------------------------------------
// 4. Event Hubs — producer send + consumer receive probe
// ---------------------------------------------------------------------------
{
  const hub = `ws9-hub-${Date.now()}`;
  const conn = eh.ehConnectionString(EH_PORT, SB_KEY, hub);
  const producer = new EventHubProducerClient(conn, {
    retryOptions: { maxRetries: 0, timeoutInMs: 10_000 },
  });
  const consumer = new EventHubConsumerClient(
    EventHubConsumerClient.defaultConsumerGroupName,
    conn,
    { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } },
  );
  try {
    const events = [
      { missionId: "ws9-mission-1", seq: 1, body: `eh-a-${Date.now()}` },
      { missionId: "ws9-mission-1", seq: 2, body: `eh-b-${Date.now()}` },
    ];
    await run("eh/sendMissionEvents", async () => {
      const n = await eh.sendMissionEvents(producer, events);
      return { sent: n };
    });

    const ok = await run("eh/receiveMissionEvents", async () => {
      const res = await eh.receiveMissionEvents(
        consumer,
        events.map((e) => JSON.stringify(e)),
        20_000,
      );
      if (!res.roundTrip) {
        throw new Error(
          `consumer observed ${res.events.length} events (expected ${events.length}) — ` +
          "EH lane PARTIAL (5673 routes /eventhubs/ addresses to QueueStore semantics; " +
          "no $management responder), per docs/WIRE_PARITY.md",
        );
      }
      return { received: res.events.length };
    });
    if (!ok) console.log("[ws9] DIVERGENCE eh: 5673 lane PARTIAL — witnessed, not fixed in this lane");
  } finally {
    await close(producer);
    await close(consumer);
  }
}

console.log(`[ws9] probe complete: ${failures} failed step(s)`);
process.exit(failures > 0 ? 1 : 0);
