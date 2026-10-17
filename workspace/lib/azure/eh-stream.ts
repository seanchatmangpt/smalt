/**
 * Event Hubs mission-event stream — producer send + consumer receive probe.
 *
 * Targets the smalt EH AMQP lane (sb://127.0.0.1:5673, EntityPath required
 * in the connection string). Auth shape mirrors
 * test/sdk-full/ts-reality.test.mjs: development-emulator connection string
 * whose SharedAccessKey matches the broker verifier seeded at boot.
 *
 * Honest wire status: docs/WIRE_PARITY.md documents the 5673 lane as
 * PARTIAL — Smalt.Amqp.Connection never consults the listener mode flag, so
 * an address containing `/eventhubs/` routes to QueueStore semantics rather
 * than Smalt.Messaging.EventHubs, and the $management link has no responder.
 * SDK bootstrapping (getEventHubProperties) can therefore time out; the
 * probe witnesses whichever side is real on the wire today and records
 * divergence instead of papering over it.
 */

import {
  earliestEventPosition,
} from "@azure/event-hubs";
import type {
  EventHubProducerClient,
  EventHubConsumerClient,
  ReceivedEventData,
} from "@azure/event-hubs";

export const DEFAULT_EH_PORT = Number(
  process.env.NEXT_PUBLIC_SMALT_EH_PORT || 5673,
);

/** Build the EH emulator connection string (EntityPath mandatory). */
export function ehConnectionString(
  ehPort: number,
  sharedKey: string,
  hubName: string,
): string {
  return (
    `Endpoint=sb://127.0.0.1:${ehPort};SharedAccessKeyName=RootManageSharedAccessKey;` +
    `SharedAccessKey=${sharedKey};EntityPath=${hubName};UseDevelopmentEmulator=true`
  );
}

/** A mission event to stream. */
export interface MissionEvent {
  missionId: string;
  seq: number;
  body: string;
}

/**
 * Send a batch of mission events. Returns the number accepted by the SDK
 * send path (link attach + send resolved).
 */
export async function sendMissionEvents(
  producer: EventHubProducerClient,
  events: MissionEvent[],
  timeoutMs = 20_000,
): Promise<number> {
  const batch = await producer.createBatch({ abortSignal: AbortSignal.timeout(timeoutMs) });
  for (const e of events) {
    if (!batch.tryAdd({ body: JSON.stringify(e), messageId: `${e.missionId}-${e.seq}` })) {
      throw new Error(`batch.tryAdd rejected event seq=${e.seq}`);
    }
  }
  await producer.sendBatch(batch, { abortSignal: AbortSignal.timeout(timeoutMs) });
  return events.length;
}

export interface ReceiveProbeResult {
  /** Events observed by the consumer within the deadline. */
  events: ReceivedEventData[];
  /** True when every sent body was observed. */
  roundTrip: boolean;
}

/**
 * Subscribe from `earliest` and collect events until the deadline or until
 * every expected body has been seen.
 */
export async function receiveMissionEvents(
  consumer: EventHubConsumerClient,
  expectedBodies: string[],
  deadlineMs = 25_000,
): Promise<ReceiveProbeResult> {
  const expected = new Set(expectedBodies);
  const events: ReceivedEventData[] = [];
  const subscription = await consumer.subscribe(
    {
      processEvents: async (received) => {
        for (const e of received) {
          events.push(e);
          expected.delete(String(e.body));
        }
      },
      processError: async () => {
        /* recorded via roundTrip result, not swallowed: roundTrip is the witness */
      },
    },
    // SDK v6 shape: EventPosition objects carry offset/sequenceNumber/
    // enqueuedOn — `{ earliest: true }` is rejected at runtime (witnessed).
    // R23 fix: earliestEventPosition is already an EventPosition ({offset:"-1"});
    // nesting it under offset produced an invalid nested shape.
    { startPosition: earliestEventPosition, maxWaitTimeInSeconds: 5 },
  );
  const deadline = Date.now() + deadlineMs;
  while (expected.size > 0 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 500));
  }
  await subscription.close();
  return { events, roundTrip: expected.size === 0 };
}
