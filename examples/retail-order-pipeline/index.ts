// ex2-retail-order-pipeline — Fortune-500 archetype: retail order pipeline.
// Service Bus queue legs (send/complete, deferral, lock renewal, DLQ),
// Event Hubs partition-pinned send + Cosmos-etag-CAS checkpoint exactly-once
// consume, Cosmos order-document etag CAS. Every leg is independently fenced
// (a failed leg records its verdict; the run always produces a result line).
// Wire contract: official @azure/* SDKs against the smalt substrate. No lib/
// imports, no mocks, no fixed sleeps — waits ride the harness boundedPoll.
import { ServiceBusClient } from "@azure/service-bus";
import {
  EventHubProducerClient,
  EventHubConsumerClient,
  earliestEventPosition,
} from "@azure/event-hubs";
import { CosmosClient, type Container } from "@azure/cosmos";
import type { TokenCredential } from "@azure/core-auth";
import { check, GREEN, RD, type WfResult } from "../../verification/ts/harness/enum.ts";
import { boundedPoll } from "../../verification/ts/harness/poll.ts";
import {
  SmaltTokenCredential,
  TENANT,
  CLIENT,
  SECRET,
} from "../../verification/ts/harness/credential.ts";

// --- environment (localhost defaults; env-var retarget per README) --------
const TLS = process.env.SMALT_EX2_TLS ?? "https://localhost:9444";
const AMQP_PORT = Number(process.env.SMALT_EX2_AMQP_PORT ?? 5672);
const EH_PORT = Number(process.env.SMALT_EX2_EH_PORT ?? 5673);
const SB_KEY = process.env.SMALT_SB_SHARED_KEY ?? "ws8sharedkey";
const SUB = "11111111-1111-1111-1111-111111111111";
const NS_RG = "ex2retailrg";
const NS = "ex2retailns";

type Check = WfResult["checks"][number];

function sbConn(entity: string): string {
  return (
    `Endpoint=sb://127.0.0.1:${AMQP_PORT};SharedAccessKeyName=RootManageSharedAccessKey;` +
    `SharedAccessKey=${SB_KEY};EntityPath=${entity};UseDevelopmentEmulator=true`
  );
}

function ehConn(entity: string): string {
  return (
    `Endpoint=sb://127.0.0.1:${EH_PORT};SharedAccessKeyName=RootManageSharedAccessKey;` +
    `SharedAccessKey=${SB_KEY};EntityPath=${entity};UseDevelopmentEmulator=true`
  );
}

async function boundedClose(h: any, ms = 8000): Promise<void> {
  await Promise.race([
    Promise.resolve(h.close()).catch(() => {}),
    // SLEEP-CLASS: POLL-STEP — bounded drain deadline on the real close
    // observable; SDK close() resolves or the kill-budget fires.
    new Promise((r) => setTimeout(r, ms)),
  ]);
}

// ARM PUT namespace + queue over the TLS twin (wf3 pattern).
async function armPutQueue(
  cred: TokenCredential,
  name: string,
  props: Record<string, unknown>,
): Promise<void> {
  const token = await cred.getToken("https://management.azure.com/.default");
  const nsUrl =
    `${TLS}/subscriptions/${SUB}/resourceGroups/${NS_RG}/providers/` +
    `Microsoft.ServiceBus/namespaces/${NS}?api-version=2021-04-01`;
  await fetch(nsUrl, {
    method: "PUT",
    headers: { authorization: `Bearer ${token.token}`, "content-type": "application/json" },
    body: JSON.stringify({ location: "smalt", skuName: "Standard" }),
  });
  const url =
    `${TLS}/subscriptions/${SUB}/resourceGroups/${NS_RG}/providers/` +
    `Microsoft.ServiceBus/namespaces/${NS}/queues/${name}?api-version=2021-04-01`;
  const res = await fetch(url, {
    method: "PUT",
    headers: { authorization: `Bearer ${token.token}`, "content-type": "application/json" },
    body: JSON.stringify({ location: "smalt", properties: props }),
  });
  if (!res.ok) throw new Error(`queue PUT ${name} -> ${res.status}`);
}

// Cosmos container proxy with the /id partition-key definition seeded (wf2
// pattern: substrate docs engine enforces id == pk, colls GET answers 404).
function orderContainer(cosmos: CosmosClient, db: string): Container {
  const cont = cosmos.database(db).container("orders");
  (cosmos as any).clientContext.partitionKeyDefinitionCache[cont.url] = {
    path: "/id",
    paths: ["/id"],
    kind: "Hash",
    version: 1,
  };
  return cont;
}

// CheckpointStore-style exactly-once consumer state in Cosmos: one doc per
// partition holding the highest durably-processed sequence number, updated
// with etag CAS (IfMatch). 412 = another writer already advanced the
// checkpoint (duplicate delivery) -> the event is skipped, never double-
// applied. This is the validated wf2/wf3 convergence: cosmos etag race law
// (exactly one 200, rest 412) applied as a consumer checkpoint store.
class CosmosCheckpointStore {
  cont: Container;
  db: string;
  constructor(cont: Container, db: string) {
    this.cont = cont;
    this.db = db;
  }
  private async doc(part: string) {
    return this.cont.item(`ckpt-${this.db}-${part}`, `ckpt-${this.db}-${part}`);
  }
  async current(part: string): Promise<number> {
    try {
      const r = await (await this.doc(part)).read();
      return r.resource?.seq ?? -1;
    } catch {
      return -1;
    }
  }
  // CAS-advance; returns true if this caller won (event may be applied),
  // false if a concurrent writer holds the newer checkpoint (duplicate).
  async advance(part: string, seq: number): Promise<boolean> {
    for (let attempt = 0; attempt < 5; attempt++) {
      let etag: string | undefined;
      let cur = -1;
      try {
        const r = await (await this.doc(part)).read();
        etag = r.etag;
        cur = r.resource?.seq ?? -1;
      } catch {
        /* not found -> create path */
      }
      if (cur >= seq) return false; // already durably processed: duplicate
      try {
        if (etag === undefined) {
          await this.cont.items.upsert({ id: `ckpt-${this.db}-${part}`, seq });
        } else {
          await (await this.doc(part)).replace(
            { id: `ckpt-${this.db}-${part}`, seq },
            { accessCondition: { type: "IfMatch", condition: etag } },
          );
        }
        return true;
      } catch (e: any) {
        if (e?.code === 412 || e?.statusCode === 412) continue; // lost race -> re-read
        throw e;
      }
      }
    throw new Error(`checkpoint CAS did not converge for partition ${part}`);
  }
}

export async function run(): Promise<WfResult> {
  const checks: Check[] = [];
  const p = (name: string, verdict: string, detail: string) =>
    checks.push(check(name, verdict, detail));
  const noRetry = { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } };
  const ts = Date.now() % 100000;
  const cred = new SmaltTokenCredential(`${TLS}/${TENANT}/oauth2/v2.0/token`);

  // ============================================================ SB legs ====
  // --- 1. order intake: send 10 -> peekLock receive -> complete ------------
  {
    const queue = `ex2retail-ord-${ts}`;
    let c: ServiceBusClient | null = null;
    try {
      await armPutQueue(cred, queue, {});
      c = new ServiceBusClient(sbConn(queue), noRetry);
      await c.createSender(queue).sendMessages(
        Array.from({ length: 10 }, (_, i) => ({
          body: { orderId: `ORD-${ts}-${i}`, amount: 10 + i },
          messageId: `ord-${i}`,
        })),
      );
      const receiver = c.createReceiver(queue, { receiveMode: "peekLock" });
      const batch = await receiver.receiveMessages(10, { maxWaitTimeInMs: 15_000 });
      const ids = batch.map((m: any) => m.body?.orderId);
      const fifo = ids.every((v: string, i: number) =>
        v === `ORD-${ts}-${i}`,
      );
      for (const m of batch) await receiver.completeMessage(m);
      p("sb-send-receive-complete",
        batch.length === 10 && fifo ? GREEN
          : batch.length === 0
            ? RD("KD-115") // plain-queue zero-delivery on flow credit (registered)
            : "FAIL",
        batch.length === 0
          ? `zero-delivery (KD-115 registered): received=0/10, send resolved — attach+flow+CBS OK, no delivery on receiver-link flow credit`
          : `received=${batch.length}/10 fifo=${fifo}`);
      await boundedClose(receiver);
    } catch (e: any) {
      p("sb-send-receive-complete", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
    } finally {
      if (c) await boundedClose(c);
    }
  }

  // --- 2. deferral: receive -> defer -> receiveDeferredMessage -> complete -
  {
    const queue = `ex2retail-def-${ts}`;
    let c: any = null;
    try {
      await armPutQueue(cred, queue, {});
      c = new ServiceBusClient(sbConn(queue), noRetry) as any;
      const sender = c.createSender(queue);
      await sender.sendMessages({ body: { orderId: "ORD-DEF", hold: true }, messageId: `ord-def-${ts}` });
      const receiver = c.createReceiver(queue, { receiveMode: "peekLock" });
      const [msg] = await receiver.receiveMessages(1, { maxWaitTimeInMs: 10_000 });
      if (!msg) {
        p("sb-defer-receive-deferred", RD("KD-115"),
        "not exercisable: plain-queue zero-delivery (KD-115 registered) — no delivery to defer");
      } else {
        await receiver.deferMessage(msg);
        const deferred = await receiver.receiveDeferredMessages([msg.sequenceNumber]);
        const bodyOk = deferred.length === 1 &&
          deferred[0].body?.orderId === "ORD-DEF";
        await receiver.completeMessage(deferred[0]);
        p("sb-defer-receive-deferred", bodyOk ? GREEN : "FAIL",
          `deferred=${deferred.length} bodyOk=${bodyOk} deliveryCount=${deferred[0]?.deliveryCount}`);
      }
      await boundedClose(receiver);
    } catch (e: any) {
      p("sb-defer-receive-deferred", "FAIL", `${e?.name}: ${e?.code ?? ""} ${String(e?.message).slice(0, 160)}`);
    } finally {
      if (c) await boundedClose(c);
    }
  }

  // --- 3. lock renewal: PT2S lock, renew while processing, complete OK -----
  {
    const queue = `ex2retail-lck-${ts}`;
    let c: ServiceBusClient | null = null;
    try {
      await armPutQueue(cred, queue, { lockDuration: "PT2S", maxDeliveryCount: 10 });
      c = new ServiceBusClient(sbConn(queue), noRetry);
      await c.createSender(queue).sendMessages({ body: { orderId: "ORD-SLOW" }, messageId: `ord-slow-${ts}` });
      const r = c.createReceiver(queue, { receiveMode: "peekLock", maxAutoLockRenewalDurationInMs: 0 });
      const [msg] = await r.receiveMessages(1, { maxWaitTimeInMs: 10_000 });
      if (!msg) {
        p("sb-lock-renewal", RD("KD-115"),
          "not exercisable: plain-queue zero-delivery (KD-115 registered) — no lock to renew");
      } else {
        // Hold the message past 2 lock durations by renewing on a bounded
        // poll: each probe renews (a real observable — the renew succeeds
        // while the lock lives) until elapsed >= 5500ms, then complete must
        // still succeed. If the substrate drops the lock, complete throws
        // MessageLockLost and the leg records FAIL honestly.
        const t0 = Date.now();
        let renews = 0;
        let renewErr: any = null;
        await boundedPoll(
          "lock held past 2 lock durations",
          async () => {
            try {
              await r.renewMessageLock(msg); // SLEEP-CLASS: POLL-STEP
              renews++;
            } catch (e) {
              renewErr = e;
              return true; // stop polling; complete() below records the fail
            }
            return Date.now() - t0 >= 5500 ? true : null;
          },
          20_000,
        ).catch(() => {});
        let settleErr: any = null;
        try {
          await r.completeMessage(msg);
        } catch (e) {
          settleErr = e;
        }
        const ok = !renewErr && !settleErr && renews >= 2;
        p("sb-lock-renewal", ok ? GREEN : "FAIL",
          `renews=${renews} renewErr=${renewErr?.name ?? "none"} settleErr=${settleErr?.name ?? "none"}`);
      }
      await boundedClose(r);
    } catch (e: any) {
      p("sb-lock-renewal", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
    } finally {
      if (c) await boundedClose(c);
    }
  }

  // --- 4. poison order -> DLQ after maxDeliveryCount -----------------------
  {
    const queue = `ex2retail-dlq-${ts}`;
    let c: ServiceBusClient | null = null;
    try {
      await armPutQueue(cred, queue, { maxDeliveryCount: 3 });
      c = new ServiceBusClient(sbConn(queue), noRetry);
      await c.createSender(queue).sendMessages({ body: { orderId: "ORD-POISON" }, messageId: `ord-poison-${ts}` });
      const r = c.createReceiver(queue, { receiveMode: "peekLock", maxAutoLockRenewalDurationInMs: 0 });
      let mainReceived = 0;
      for (let i = 0; i < 3; i++) {
        const [msg] = await r.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
        if (!msg) break;
        mainReceived++;
        await r.abandonMessage(msg);
      }
      const dlqR = c.createReceiver(queue, { subQueueType: "deadLetter" });
      const dlq = await dlqR.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
      const m = dlq[0] as any;
      const dcOk = typeof m?.deliveryCount === "number" && m.deliveryCount >= 3;
      const blob = JSON.stringify({
        reason: m?.deadLetterReason,
        props: m?.applicationProperties,
      });
      const reasonOk = /MaxDeliveryCount|MaximumDeliveryCount/i.test(blob);
      if (m) await r.completeMessage(m);
      const mainGot = mainReceived >= 1; // any main-queue delivery proves KD-115 not blocking
      p("sb-dlq-maxdelivery",
        dlq.length === 1 && dcOk && reasonOk ? GREEN
          : !mainGot ? RD("KD-115") : "FAIL",
        !mainGot
          ? "not exercisable: plain-queue zero-delivery (KD-115 registered) — poison order never re-delivered, DLQ never populated"
          : `dlq=${dlq.length} deliveryCount=${m?.deliveryCount} reasonHit=${reasonOk}`);
      await boundedClose(dlqR);
    } catch (e: any) {
      p("sb-dlq-maxdelivery", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
    } finally {
      if (c) await boundedClose(c);
    }
  }

  // ============================================== Event Hubs + Cosmos =====
  // --- 5. partition-pinned send (pinion: partitions 0/1 only) -------------
  const db = `ex2retail-${ts}`;
  const cosmos = new CosmosClient({
    endpoint: TLS,
    aadCredentials: cred,
    connectionPolicy: { enableEndpointDiscovery: false },
  });
  const cont = orderContainer(cosmos, db);
  const hub = `ex2retail-hub-${ts}`;
  {
    const producer = new EventHubProducerClient(ehConn(hub), noRetry);
    try {
      const props = await producer.getEventHubProperties({ abortSignal: AbortSignal.timeout(15_000) });
      const partsOk = props.partitionIds.length === 2 &&
        props.partitionIds.includes("0") && props.partitionIds.includes("1");
      p("eh-partitions-pinion", partsOk ? GREEN : "FAIL",
        `partitionIds=[${props.partitionIds.join(",")}] (pinion: fixed ["0","1"])`);
      await producer.sendBatch(
        Array.from({ length: 50 }, (_, i) => ({
          body: { orderId: `ORD-EH-0-${i}`, partitionKeyHint: "p0" },
        })),
        { partitionId: "0" },
      );
      await producer.sendBatch(
        Array.from({ length: 50 }, (_, i) => ({
          body: { orderId: `ORD-EH-1-${i}`, partitionKeyHint: "p1" },
        })),
        { partitionId: "1" },
      );
      p("eh-partition-pinned-send", GREEN, "50 events -> partition 0, 50 -> partition 1");
    } catch (e: any) {
      p("eh-partitions-pinion", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
      p("eh-partition-pinned-send", "FAIL", "hub unavailable — send leg not exercised");
      await boundedClose(producer);
      return { id: "ex2-retail", checks };
    }
    // --- 6. exactly-once consume: Cosmos-etag-CAS checkpoint store ---------
    try {
      // Cosmos leg first: persist order documents with etag CAS (upsert,
      // conditional replace OK, stale etag -> 412 precondition failed).
      const orderId = `ORD-COSMOS-${ts}`;
      const created = await cont.items.upsert({ id: orderId, status: "created", v: 0 });
      const etag = created.resource!._etag;
      await cont.item(orderId, orderId).replace(
        { id: orderId, status: "paid", v: 1 },
        { accessCondition: { type: "IfMatch", condition: etag } },
      );
      let stale412 = false;
      try {
        await cont.item(orderId, orderId).replace(
          { id: orderId, status: "shipped", v: 2 },
          { accessCondition: { type: "IfMatch", condition: etag } }, // stale
        );
      } catch (e: any) {
        stale412 = e?.code === 412 || e?.statusCode === 412;
      }
      const readback = await cont.item(orderId, orderId).read();
      p("cosmos-order-etag-cas", stale412 && readback.resource?.status === "paid" ? GREEN : "FAIL",
        `stale412=${stale412} finalStatus=${readback.resource?.status}`);

      const ckpt = new CosmosCheckpointStore(cont, db);
      const consumer = new EventHubConsumerClient("ex2cg", ehConn(hub), noRetry);
      let applied = 0;
      let duplicates = 0;
      let casErr: any = null;
      const perPartition: Record<string, number> = { "0": 0, "1": 0 };
      const subscriptions: any[] = [];
      const allDone = Promise.all(["0", "1"].map(async (pid) => {
        const s = consumer.subscribe(
          pid,
          {
            processEvents: async (events: any[]) => {
              for (const evt of events) {
                const won = await ckpt.advance(pid, evt.sequenceNumber).catch((e) => {
                  casErr = e;
                  return false;
                });
                if (won) {
                  applied++;
                  perPartition[pid]++;
                } else {
                  duplicates++;
                }
              }
            },
            processError: async () => {},
          },
          { startPosition: earliestEventPosition },
        );
        subscriptions.push(s);
      }));
      // SLEEP-CLASS: POLL-STEP — bounded drain: poll the applied+duplicate
      // count observable until all 100 events are accounted for (or budget).
      await boundedPoll(
        "exactly-once drain of 100 events",
        async () => (applied + duplicates >= 100 ? true : null),
        90_000,
      ).catch(() => {});
      for (const s of subscriptions) await s.close().catch(() => {});
      const exactlyOnce = applied === 100 && duplicates === 0 && !casErr;
      p("eh-checkpoint-exactly-once", exactlyOnce ? GREEN : "FAIL",
        `applied=${applied}/100 duplicates=${duplicates} casErr=${casErr?.name ?? "none"} ` +
        `perPartition=[${Object.entries(perPartition).map(([k, v]) => `${k}:${v}`).join(" ")}]`);
      await boundedClose(consumer);
    } catch (e: any) {
      p("cosmos-order-etag-cas", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
      p("eh-checkpoint-exactly-once", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
    }
    await boundedClose(producer);
  }

  return { id: "ex2-retail", checks };
}

// entry: build context inline and map the exit contract.
const isSubstrateUp = await (async () => {
  const net = await import("node:net");
  return new Promise<boolean>((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: AMQP_PORT, timeout: 1500 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });
})();

if (!isSubstrateUp) {
  console.error("[ex2] SUBSTRATE-DOWN: no listener on 127.0.0.1:" + AMQP_PORT);
  process.exit(2);
}

try {
  const result = await run();
  const { rollup } = await import("../../verification/ts/harness/enum.ts");
  const { ok, summary } = rollup(result);
  console.log(summary);
  process.exit(ok ? 0 : 1);
} catch (e: any) {
  console.error(`[ex2] crashed: ${e?.stack ?? e}`);
  process.exit(1);
}
