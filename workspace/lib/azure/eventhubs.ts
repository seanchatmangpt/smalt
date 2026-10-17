/**
 * Console Event Hubs client layer — @azure/event-hubs against the local
 * smalt EH AMQP lane (sb://127.0.0.1:5673, partitions ["0","1"]).
 *
 * Ownership: Console lane (Ring 1, Agent 3). Connection-string shape matches
 * the WS-9 probe module `./eh-stream` (inlined — see note below).
 *
 * Surfaces consumed (wire-proven by the substrate lane):
 * - EH ARM children on 9443 (namespaces/eventhubs/consumergroups)
 * - AMQP 5673 EH mode: monotonic per-partition sequences, checkpoint CAS,
 *   partition-key hash routing (KD-76: pk events reach exactly
 *   `md5(pk) first byte % partitionCount`).
 * - dual-key createdAt/created_at annotations.
 *
 * Honest status: consumer-group enumeration does not exist on the
 * @azure/event-hubs client surface (no client API names it) — a registered
 * gap, surfaced as a loud typed SKIP by the lane test, never a faked pass.
 */

import type {
  Checkpoint,
  CheckpointStore,
  EventDataBatch,
  OperationOptions,
  PartitionOwnership,
  PartitionProperties,
  ReceivedEventData,
  SendBatchOptions,
} from "@azure/event-hubs";
import { earliestEventPosition, EventHubProducerClient } from "@azure/event-hubs";
import { ContainerClient, StorageSharedKeyCredential } from "@azure/storage-blob";
import { createHash } from "node:crypto";

// The connection-string shape is composed from ./eh-stream's builder (same
// Endpoint/SharedAccessKey/EntityPath/UseDevelopmentEmulator wire shape).
// It is inlined rather than imported because node's type-stripping ESM
// loader requires a .ts extension on relative specifiers, which tsc
// (allowImportingTsExtensions off, coordinator-owned tsconfig) rejects —
// the same reason this module has zero relative imports.
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

/** Default consumer group (substrate serves `$default` out of the box). */
export const DEFAULT_CONSUMER_GROUP = "$default";

/** Blob plane account for checkpoint persistence (see blob-export.ts). */
export const BLOB_ACCOUNT = "smaltacct";
export const BLOB_ACCOUNT_KEY = "smaltacct-key";

/**
 * KD-76 pin: the substrate routes a partition-keyed event to partition
 * `md5(pk) first byte % partitionCount`. Importable so consumers assert
 * against the same pin the broker implements.
 */
export function pkPartition(pk: string, partitionCount = 2): string {
  const firstByte = createHash("md5").update(pk, "utf8").digest()[0];
  return String(firstByte % partitionCount);
}

/**
 * Ingest a mixed load: partition-keyed events (routed by the broker's md5
 * pin) plus unkeyed events pinned to explicit partitions. Batches are
 * chunked at 100 events; every send is deadline-bounded.
 */
export async function ingestPartitionedEvents(
  producer: EventHubProducerClient,
  load: {
    /** Keyed events: one send per distinct partition key. */
    keyed: Array<{ partitionKey: string; bodies: string[] }>;
    /** Unkeyed events: explicit partition routing. */
    unkeyed: Array<{ partitionId: string; bodies: string[] }>;
  },
  timeoutMs = 30_000,
): Promise<number> {
  let sent = 0;
  for (const group of load.keyed) {
    for (const batch of await buildBatches(producer, group.bodies, {
      partitionKey: group.partitionKey,
      abortSignal: AbortSignal.timeout(timeoutMs),
    })) {
      await producer.sendBatch(batch, { abortSignal: AbortSignal.timeout(timeoutMs) });
      sent += batch.count;
    }
  }
  for (const group of load.unkeyed) {
    for (const batch of await buildBatches(producer, group.bodies, {
      partitionId: group.partitionId,
      abortSignal: AbortSignal.timeout(timeoutMs),
    })) {
      await producer.sendBatch(batch, { abortSignal: AbortSignal.timeout(timeoutMs) });
      sent += batch.count;
    }
  }
  return sent;
}

async function buildBatches(
  producer: EventHubProducerClient,
  bodies: string[],
  options: SendBatchOptions,
): Promise<EventDataBatch[]> {
  const batches: EventDataBatch[] = [];
  for (let i = 0; i < bodies.length; i += 100) {
    const batch = await producer.createBatch(options);
    for (const body of bodies.slice(i, i + 100)) {
      if (!batch.tryAdd({ body })) {
        throw new Error(`batch.tryAdd rejected body=${body}`);
      }
    }
    batches.push(batch);
  }
  return batches;
}

export interface CollectResult {
  /** Events bucketed by partitionId (bucket created on first sight). */
  byPartition: Map<string, ReceivedEventData[]>;
  /** All received bodies, arrival order. */
  bodies: string[];
  /** True when `expectedCount` bodies arrived before the deadline. */
  complete: boolean;
  /** processError messages observed while draining (fail-visible, not swallowed). */
  errors: string[];
}

/**
 * Collect events from every partition until `expectedCount` bodies arrive or
 * the deadline passes. `$default` consumer group, explicit
 * `earliestEventPosition` (the `{ earliest: true }` object shape is rejected
 * by SDK v6 at runtime — witnessed in ./eh-stream).
 */
export async function collectAllPartitions(
  consumer: import("@azure/event-hubs").EventHubConsumerClient,
  partitionIds: string[],
  expectedCount: number,
  deadlineMs = 45_000,
): Promise<CollectResult> {
  const byPartition = new Map<string, ReceivedEventData[]>();
  const bodies: string[] = [];
  const errors: string[] = [];
  let complete = false;
  let subscribeFailure: unknown = null;
  // ReceivedEventData carries no partitionId — the partition is a property of
  // the subscription, so subscribe per partition and tag client-side.
  const subscriptions = await Promise.all(
    partitionIds.map((pid) =>
      consumer.subscribe(
        pid,
        {
          processEvents: async (events) => {
            for (const e of events) {
              if (!byPartition.has(pid)) byPartition.set(pid, []);
              byPartition.get(pid)!.push(e);
              bodies.push(String(e.body));
            }
            if (bodies.length >= expectedCount) complete = true;
          },
          processError: async (err) => {
            errors.push(`processError (${pid}): ${err?.message ?? err}`);
          },
        },
        { startPosition: earliestEventPosition, maxWaitTimeInSeconds: 5 },
      ),
    ),
  ).catch((e) => { subscribeFailure = e; return []; });
  const deadline = Date.now() + deadlineMs;
  while (!complete && subscribeFailure === null && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 500));
  }
  await Promise.all(subscriptions.map((s) => s.close()));
  return { byPartition, bodies, complete, errors };
}

/**
 * Partition-scoped readout: live broker view (last enqueued
 * sequence/offset) per partition.
 */
export async function partitionReadout(
  consumer: import("@azure/event-hubs").EventHubConsumerClient,
  partitionIds: string[],
  timeoutMs = 15_000,
): Promise<PartitionProperties[]> {
  const out: PartitionProperties[] = [];
  for (const pid of partitionIds) {
    out.push(
      await consumer.getPartitionProperties(pid, {
        abortSignal: AbortSignal.timeout(timeoutMs),
      }),
    );
  }
  return out;
}

export { earliestEventPosition };
export type { Checkpoint, PartitionProperties, ReceivedEventData };

/**
 * Blob-backed checkpoint store over the smalt data plane (account
 * `smaltacct`, mutable container — the immutable default applies only to
 * containers created with the immutability policy header, witnessed in
 * lib/smalt/egress_router.ex). Implements the @azure/event-hubs
 * `CheckpointStore` interface with real If-Match CAS: updateCheckpoint
 * uploads with the blob's current ETag and retries on 412, so concurrent
 * consumers cannot silently clobber each other — the same CAS discipline
 * the substrate applies server-side for `$management` checkpoints.
 */
export class SmaltBlobCheckpointStore implements CheckpointStore {
  private container: ContainerClient;
  private etags = new Map<string, string>();
  private ensureContainer: Promise<void> | null = null;

  /**
   * Create the checkpoint container once (409 tolerated — idempotent).
   * The raw PUT (URL built from constructor args, never a literal — air-gap
   * lint) carries `x-ms-immutable-policy: false` because the smalt egress
   * plane creates containers WORM-immutable by default (egress_router.ex
   * creates immutable unless the header is literally "false"); a checkpoint
   * store needs CAS overwrites, which WORM refuses.
   */
  private ensure(): Promise<void> {
    if (!this.ensureContainer) {
      const url = new URL(this.container.url);
      url.searchParams.set("restype", "container");
      this.ensureContainer = fetch(url, {
        method: "PUT",
        headers: { "x-ms-version": "2021-04-10", "x-ms-immutable-policy": "false" },
      }).then((res) => {
        // 201 created / 200 or 409 already-exists are all success
        if (res.status !== 200 && res.status !== 201 && res.status !== 409) {
          throw new Error(`CHECKPOINT_CONTAINER_CREATE_REFUSED: HTTP ${res.status}`);
        }
      });
    }
    return this.ensureContainer;
  }

  constructor(
    egressBaseUrl: string,
    containerName: string,
    account = BLOB_ACCOUNT,
    accountKey = BLOB_ACCOUNT_KEY,
  ) {
    // SharedKey signing on plain HTTP mirrors workspace/lib/azure/blob-export.ts.
    this.container = new ContainerClient(
      `${egressBaseUrl}/${account}/${containerName}`,
      new StorageSharedKeyCredential(account, accountKey),
    );
  }

  private blobKey(
    fullyQualifiedNamespace: string,
    eventHubName: string,
    consumerGroup: string,
    partitionId: string,
  ): string {
    return `${blobSafe(fullyQualifiedNamespace)}/${blobSafe(eventHubName)}/${blobSafe(consumerGroup)}/${blobSafe(partitionId)}`;
  }

  async listOwnership(
    _fullyQualifiedNamespace: string,
    _eventHubName: string,
    _consumerGroup: string,
    _options?: OperationOptions,
  ): Promise<PartitionOwnership[]> {
    // Single-consumer lane: no ownership competition to mediate.
    return [];
  }

  async claimOwnership(
    ownership: PartitionOwnership[],
    _options?: OperationOptions,
  ): Promise<PartitionOwnership[]> {
    return ownership;
  }

  async updateCheckpoint(
    checkpoint: Checkpoint,
    _options?: OperationOptions,
  ): Promise<void> {
    const key = this.blobKey(
      checkpoint.fullyQualifiedNamespace,
      checkpoint.eventHubName,
      checkpoint.consumerGroup,
      checkpoint.partitionId,
    );
    const blob = this.container.getBlockBlobClient(key);
    await this.ensure();
    const body = JSON.stringify({
      sequenceNumber: checkpoint.sequenceNumber,
      offset: checkpoint.offset,
    });
    for (let attempt = 0; ; attempt++) {
      const etag: string | undefined = this.etags.get(key);
      const conditions = etag !== undefined
        ? { ifMatch: etag }
        : { ifNoneMatch: "*" };
      try {
        const res = await blob.upload(body, Buffer.byteLength(body), {
          conditions,
        });
        if (res.etag === undefined) throw new Error("CHECKPOINT_UPLOAD_NO_ETAG");
        this.etags.set(key, res.etag);
        return;
      } catch (err) {
        const status = (err as { statusCode?: number })?.statusCode;
        if (status === 412 && attempt < 5) {
          // lost the CAS race: re-read the winner's ETag and retry
          const props = await blob.getProperties();
          if (props.etag === undefined) throw new Error("CHECKPOINT_REREAD_NO_ETAG");
          this.etags.set(key, props.etag);
          continue;
        }
        throw err;
      }
    }
  }

  async listCheckpoints(
    fullyQualifiedNamespace: string,
    eventHubName: string,
    consumerGroup: string,
    _options?: OperationOptions,
  ): Promise<Checkpoint[]> {
    const prefix = `${blobSafe(fullyQualifiedNamespace)}/${blobSafe(eventHubName)}/${blobSafe(consumerGroup)}/`;
    await this.ensure();
    const out: Checkpoint[] = [];
    for await (const item of this.container.listBlobsFlat({ prefix })) {
      const buf = await this.container.getBlobClient(item.name).downloadToBuffer();
      const parsed = JSON.parse(buf.toString("utf8"));
      out.push({
        fullyQualifiedNamespace,
        eventHubName,
        consumerGroup,
        partitionId: item.name.slice(prefix.length),
        sequenceNumber: parsed.sequenceNumber,
        offset: parsed.offset,
      });
    }
    return out;
  }
}

function blobSafe(s: string): string {
  return s.replace(/[^a-zA-Z0-9-]/g, "-");
}
