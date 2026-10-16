/**
 * Service Bus mission telemetry — send / receive / complete + session probe.
 *
 * Targets the smalt AMQP broker (sb://127.0.0.1:5672). Auth shape mirrors
 * test/sdk-full/ts-reality.test.mjs: a development-emulator connection
 * string whose SharedAccessKey matches the broker verifier seeded at boot
 * (SMALT_WS9_SB_SHARED_KEY). Queues are provisioned over the ARM control
 * plane (port 9443) with raw PUTs — namespace first (flat `skuName` required
 * by the smalt GraphLaw shape), then the queue entity.
 *
 * Honest wire status (docs/WIRE_PARITY.md + ts-reality witnesses): the
 * broker completes CBS auth, link attach and queue ensure, and SDK sends
 * resolve — but receiver links historically get no deliveries (deliver
 * path never dequeues). The probe witnesses whichever side is real today
 * and fails loudly on divergence.
 */

import type {
  ServiceBusClient,
  ServiceBusSender,
  ServiceBusReceiver,
  ServiceBusReceivedMessage,
} from "@azure/service-bus";

/** Mission telemetry event carried on the queue. */
export interface TelemetryEvent {
  missionId: string;
  kind: "probe" | "status" | "alert";
  detail: string;
  at: string;
}

/** Build the emulator connection string the @azure/service-bus SDK expects. */
export function sbConnectionString(
  amqpPort: number,
  sharedKey: string,
  entityPath?: string,
): string {
  const entity = entityPath ? `;EntityPath=${entityPath}` : "";
  return (
    `Endpoint=sb://127.0.0.1:${amqpPort};SharedAccessKeyName=RootManageSharedAccessKey;` +
    `SharedAccessKey=${sharedKey}${entity};UseDevelopmentEmulator=true`
  );
}

/** Provision the sb namespace + queue over the ARM control plane (raw PUT). */
export async function ensureQueue(
  armBase: string,
  queueName: string,
  props: Record<string, unknown> = {},
  timeoutMs = 30_000,
): Promise<number> {
  const sub = "00000000-0000-0000-0000-000000000000";
  const nsBase =
    `${armBase}/subscriptions/${sub}/resourceGroups/ws9-rg/providers/` +
    `Microsoft.ServiceBus/namespaces/ws9-ns`;
  await fetch(`${nsBase}?api-version=2021-04-01`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ location: "smalt", skuName: "Standard" }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const res = await fetch(
    `${nsBase}/queues/${queueName}?api-version=2021-04-01`,
    {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ location: "smalt", properties: props }),
      signal: AbortSignal.timeout(timeoutMs),
    },
  );
  if (![200, 201].includes(res.status)) {
    throw new Error(`queue ${queueName} PUT → ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  return res.status;
}

/** Send one telemetry event; resolves only on broker acceptance. */
export async function sendTelemetry(
  sender: ServiceBusSender,
  event: TelemetryEvent,
  timeoutMs = 20_000,
): Promise<void> {
  await sender.sendMessages(
    { body: event, messageId: `${event.missionId}-${event.kind}-${Date.now()}` },
    { abortSignal: AbortSignal.timeout(timeoutMs) },
  );
}

export interface ReceiveProbeResult {
  received: number;
  messages: Array<Pick<ServiceBusReceivedMessage, "body" | "messageId"> & {
    sessionId?: string;
  }>;
  completed: number;
}

/**
 * Receive up to `max` messages and complete them. Bounded wait — a broker
 * that never delivers resolves with zero messages rather than hanging.
 */
export async function receiveAndComplete(
  receiver: ServiceBusReceiver,
  max: number,
  maxWaitTimeInMs = 8_000,
): Promise<ReceiveProbeResult> {
  const msgs = await receiver.receiveMessages(max, {
    maxWaitTimeInMs,
    abortSignal: AbortSignal.timeout(maxWaitTimeInMs * 2),
  });
  for (const m of msgs) {
    if (typeof (m as unknown as { complete?: unknown })?.complete !== "function") {
      // Witness raw delivered shape rather than an opaque TypeError.
      throw new Error(
        `delivered entry lacks complete(): ${JSON.stringify({
          keys: m ? Object.keys(m).slice(0, 14) : String(m),
          body: m?.body,
          sessionId: m?.sessionId,
        })}`,
      );
    }
    // v7 typings put settlement on the receiver (completeMessage); the runtime
    // delivery shape above is witnessed directly. Type-level unblock only.
    await (m as unknown as { complete(o?: unknown): Promise<void> }).complete({
      abortSignal: AbortSignal.timeout(10_000),
    });
  }
  return {
    received: msgs.length,
    messages: msgs.map((m: ServiceBusReceivedMessage) => ({
      body: m.body,
      messageId: m.messageId,
      sessionId: m.sessionId,
    })),
    completed: msgs.length,
  };
}
