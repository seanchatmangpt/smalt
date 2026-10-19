// wf3-messaging — service-bus send/receive/complete, lock-lost, DLQ via
// maxDeliveryCount, sessions FIFO; event-hubs partition-pinned exactly-once.
// Every leg is independently fenced: a failed leg records its verdict and
// the workflow always produces a result line (honest, never a crash-loss).
import { ServiceBusClient } from "@azure/service-bus";
import {
  EventHubProducerClient,
  EventHubConsumerClient,
  earliestEventPosition,
} from "@azure/event-hubs";
import { check, GREEN, type WfResult } from "../harness/enum.ts";
import type { SubstrateCoords, CredMode } from "../harness/credential.ts";
import { boundedPoll } from "../harness/poll.ts";

type Ctx = { coords: SubstrateCoords; runid: string; cred: any; credMode: CredMode };

const SB_KEY = process.env.SMALT_TS_SB_SHARED_KEY ?? "unset";
const SUB = "11111111-1111-1111-1111-111111111111";

function sbConn(port: number, entity: string): string {
  return (
    `Endpoint=sb://127.0.0.1:${port};SharedAccessKeyName=RootManageSharedAccessKey;` +
    `SharedAccessKey=${SB_KEY};EntityPath=${entity};UseDevelopmentEmulator=true`
  );
}

async function boundedClose(h: any, ms = 8000): Promise<void> {
  await Promise.race([
    Promise.resolve(h.close()).catch(() => {}),
    // SLEEP-CLASS: POLL-STEP — bounded drain deadline on the real close
    // observable; the SDK close() resolves or the kill-budget fires.
    new Promise((r) => setTimeout(r, ms)),
  ]);
}

export async function run(ctx: Ctx): Promise<WfResult> {
  const checks: WfResult["checks"] = [];
  const p = (name: string, verdict: string, detail: string) => checks.push(check(name, verdict, detail));
  const noRetry = { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } };

  // --- SB: send 20 -> batch receive -> complete ----------------------------
  {
    const queue = `wf3plain${Date.now() % 100000}`;
    let c: ServiceBusClient | null = null;
    try {
      c = new ServiceBusClient(sbConn(ctx.coords.amqpPort, queue), noRetry);
      await armPutQueue(ctx, queue, {});
      await c.createSender(queue).sendMessages(
        Array.from({ length: 20 }, (_, i) => ({ body: { i }, messageId: `m${i}` })),
      );
      const receiver = c.createReceiver(queue, "peekLock");
      const batch = await receiver.receiveMessages(20, { maxWaitTimeInMs: 15_000 });
      const bodies = batch.map((m: any) => m.body?.i);
      const fifo = bodies.every((v: number, i: number) => v === i);
      for (const m of batch) await m.complete();
      p("sb-send20-receive-complete",
        batch.length === 20 && fifo ? GREEN : "FAIL",
        `received=${batch.length}/20 fifo=${fifo}` +
        (batch.length === 0
          ? " — receiver-delivery gap: attach+flow+CBS succeed and send resolves, but no delivery is produced on receiver-link flow credit (send-side only on the wire)"
          : ""));
      await boundedClose(receiver);
    } catch (e: any) {
      p("sb-send20-receive-complete", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
    } finally {
      if (c) await boundedClose(c);
    }
  }

  // red-against-missing-plane: dead AMQP port -> typed connect failure
  {
    try {
      const dead = new ServiceBusClient(sbConn(1, "x"), noRetry);
      await dead.createSender("x").sendMessages({ body: "x" });
      p("dead-port-plane-check", "FAIL", "send against dead AMQP port resolved");
    } catch (err: any) {
      const real = /ECONNREFUSED|ECONNRESET|fetch failed|general error|AggregateError|Unknown/i.test(
        String(err?.name) + String(err?.message),
      );
      p("dead-port-plane-check", real ? GREEN : "FAIL",
        `dead AMQP typed failure (${err?.name}: ${String(err?.message).slice(0, 100)})`);
    }
  }

  // --- PT1S lock queue, receiver without renewal -> MessageLockLost --------
  {
    const lockQueue = `wf3lock${Date.now() % 100000}`;
    let c: ServiceBusClient | null = null;
    try {
      await armPutQueue(ctx, lockQueue, { lockDuration: "PT1S", maxDeliveryCount: 10 });
      c = new ServiceBusClient(sbConn(ctx.coords.amqpPort, lockQueue), noRetry);
      await c.createSender(lockQueue).sendMessages({ body: "lock-me" });
      const lr = c.createReceiver(lockQueue, "peekLock");
      const [msg] = await lr.receiveMessages(1, { maxWaitTimeInMs: 10_000 });
      if (!msg) {
        p("sb-message-lock-lost", "FAIL",
          "no delivery — receiver-delivery gap leaves the lock-expiry leg unexercisable over the SDK");
      } else {
        // No renewal. Poll the settle itself until it fails — the observed
        // server-side lock (PT1S) owns the interval; the poll owns the deadline.
        const err: any = await boundedPoll(
          "settle after lock expiry",
          async () => {
            try {
              await msg.complete();
              return null;
            } catch (e) {
              return e;
            }
          },
          20_000,
        ).catch((e) => e);
        const lockLost = /MessageLockLost|lock.*lost/i.test(String(err?.name ?? "") + String(err?.message ?? ""));
        p("sb-message-lock-lost", lockLost ? GREEN : "FAIL",
          `settle after PT1S expiry surfaced ${lockLost ? "MessageLockLost" : String(err?.name ?? "?")}`);
      }
      await boundedClose(lr);
    } catch (e: any) {
      p("sb-message-lock-lost", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
    } finally {
      if (c) await boundedClose(c);
    }
  }

  // --- maxDeliveryCount=3 abandon x3 -> DLQ receive ------------------------
  {
    const dlqQueue = `wf3dlq${Date.now() % 100000}`;
    let c: ServiceBusClient | null = null;
    try {
      await armPutQueue(ctx, dlqQueue, { maxDeliveryCount: 3 });
      c = new ServiceBusClient(sbConn(ctx.coords.amqpPort, dlqQueue), noRetry);
      await c.createSender(dlqQueue).sendMessages({ body: "poison" });
      const r = c.createReceiver(dlqQueue, "peekLock");
      for (let i = 0; i < 3; i++) {
        const [msg] = await r.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
        if (!msg) break;
        await msg.abandon();
      }
      await boundedClose(r);
      const dlqR = c.createReceiver(dlqQueue, "$DeadLetterQueue");
      const dlq = await dlqR.receiveMessages(1, { maxWaitTimeInMs: 8_000 });
      const hasReason = dlq.length === 1 &&
        /MaxDeliveryCount|MaximumDeliveryCount/i.test(
          JSON.stringify(dlq[0]?.deadLetterReason ?? dlq[0]?.applicationProperties ?? ""),
        );
      if (dlq[0]) await dlq[0].complete();
      p("sb-dlq-maxdelivery", hasReason ? GREEN : "FAIL",
        `DLQ size=${dlq.length} reason=${JSON.stringify(dlq[0]?.deadLetterReason ?? null)}`);
      await boundedClose(dlqR);
    } catch (e: any) {
      p("sb-dlq-maxdelivery", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
    } finally {
      if (c) await boundedClose(c);
    }
  }

  // --- sessions FIFO --------------------------------------------------------
  {
    const sessQueue = `wf3sess${Date.now() % 100000}`;
    let c: ServiceBusClient | null = null;
    try {
      await armPutQueue(ctx, sessQueue, { requiresSession: true });
      c = new ServiceBusClient(sbConn(ctx.coords.amqpPort, sessQueue), noRetry);
      await c.createSender(sessQueue).sendMessages(
        Array.from({ length: 5 }, (_, i) => ({ body: { seq: i }, sessionId: "S1" })),
      );
      const sr = await c.acceptSession(sessQueue, "S1");
      const got: number[] = [];
      let settleMissing = false;
      for (;;) {
        const msgs = await sr.receiveMessages(5, { maxWaitTimeInMs: 4_000 });
        if (!msgs.length) break;
        for (const m of msgs) {
          got.push((m as any).body?.seq);
          if (typeof (m as any).complete === "function") await m.complete();
          else settleMissing = true;
        }
      }
      const fifoOk = got.length === 5 && got.every((v, i) => v === i);
      p("sb-session-fifo", fifoOk ? GREEN : "FAIL",
        `received=[${got.join(",")}]${settleMissing ? " (deliveries lack settle methods — delivery-shape divergence)" : " settled+completed"}`);
      await boundedClose(sr);
    } catch (e: any) {
      p("sb-session-fifo", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
    } finally {
      if (c) await boundedClose(c);
    }
  }

  // --- event hubs: 200 events pinned to partitions 0/1, exactly-once -------
  {
    const hub = `wf3hub${Date.now() % 100000}`;
    const ehConn =
      `Endpoint=sb://127.0.0.1:${ctx.coords.ehPort};SharedAccessKeyName=RootManageSharedAccessKey;` +
      `SharedAccessKey=${SB_KEY};EntityPath=${hub};UseDevelopmentEmulator=true`;
    const producer = new EventHubProducerClient(ehConn, noRetry);
    try {
      await producer.getEventHubProperties({ abortSignal: AbortSignal.timeout(15_000) });
    } catch (err: any) {
      p("eh-hub-up", "FAIL", `getEventHubProperties: ${err?.name}: ${String(err?.message).slice(0, 160)}`);
      await boundedClose(producer);
      return { id: "wf3", checks };
    }
    p("eh-hub-up", GREEN, "hub properties via $management link");
    await producer.sendBatch(
      Array.from({ length: 100 }, (_, i) => ({ body: { n: i } })),
      { partitionId: "0" },
    );
    await producer.sendBatch(
      Array.from({ length: 100 }, (_, i) => ({ body: { n: 100 + i } })),
      { partitionId: "1" },
    );
    p("eh-send-200", GREEN, "100 events to partition 0, 100 to partition 1");

    const consumer = new EventHubConsumerClient("tsconsumergroup", ehConn, noRetry);
    const seen = new Map<number, number>();
    let duplicates = 0;
    const allSeen = new Promise<void>((resolve) => {
      let cnt = 0;
      consumer.subscribe(
        {
          processEvents: async (events: any[]) => {
            for (const evt of events) {
              const n = evt.body?.n;
              if (seen.has(n)) duplicates++;
              seen.set(n, (seen.get(n) ?? 0) + 1);
              cnt++;
            }
            if (cnt >= 200) resolve();
          },
          processError: async () => {},
        },
        { startPosition: earliestEventPosition },
      );
    });
    // SLEEP-CLASS: POLL-STEP — bounded drain deadline: processEvent resolves
    // the promise on the 200th real event, or the 90s kill-budget fires.
    await Promise.race([allSeen, new Promise((r) => setTimeout(r, 90_000))]);
    const exactlyOnce = seen.size === 200 && duplicates === 0;
    p("eh-exactly-once", exactlyOnce ? GREEN : "FAIL",
      `unique=${seen.size}/200 duplicates=${duplicates}`);
    await boundedClose(consumer);
    await boundedClose(producer);
  }

  return { id: "wf3", checks };
}

async function armPutQueue(
  ctx: Ctx,
  name: string,
  props: Record<string, unknown>,
): Promise<void> {
  const token = await ctx.cred.getToken("https://management.azure.com/.default");
  const base = ctx.coords.tls; // SDK-lawful https; TLS twin serves the ARM router
  const rg = "wf3nsrg";
  const ns = "wf3ns";
  const nsUrl =
    `${base}/subscriptions/${SUB}/resourceGroups/${rg}/providers/` +
    `Microsoft.ServiceBus/namespaces/${ns}?api-version=2021-04-01`;
  await fetch(nsUrl, {
    method: "PUT",
    headers: { authorization: `Bearer ${token.token}`, "content-type": "application/json" },
    body: JSON.stringify({ location: "smalt", skuName: "Standard" }),
  });
  const url =
    `${base}/subscriptions/${SUB}/resourceGroups/${rg}/providers/` +
    `Microsoft.ServiceBus/namespaces/${ns}/queues/${name}?api-version=2021-04-01`;
  const res = await fetch(url, {
    method: "PUT",
    headers: { authorization: `Bearer ${token.token}`, "content-type": "application/json" },
    body: JSON.stringify({ location: "smalt", properties: props }),
  });
  if (!res.ok) throw new Error(`queue PUT ${name} -> ${res.status}`);
}
