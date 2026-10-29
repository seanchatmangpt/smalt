/**
 * P10 Elastic Snapback — client-side rollback on server sync refusal.
 *
 * Server contract (SYNC-1, FR-SNC-006): a refusal sync response is a non-2xx
 * HTTP status with a JSON body {refusal: string, serverHeadSeq: number} where
 * `serverHeadSeq` is the server's canonical journal head at refusal time.
 *
 * On such a response the client:
 *   1. deletes every local journal record with synced===0 (un-acked, the
 *      `acked: false` field in this module's `Segment` shape — naming
 *      divergence disclosed: the pattern text says "synced===0", the journal
 *      stores it as boolean `acked`),
 *   2. resets the local seq horizon (ack cursor) to `serverHeadSeq`,
 *   3. transitions SYNC_REFUSED_BY_SERVER, then READY_STANDALONE.
 *
 * Pure/IO separation: `planSnapback` is a pure function over the segment list;
 * `snapbackWithStore` drives an async store-ops interface. The browser wires
 * it to real IndexedDB (journal-sync.applySnapback); node courts wire it to an
 * in-memory fake. Same code path, real behavior, node-testable.
 */

import type { Segment } from "./journal-sync";

/** Async store ops the snapback needs; real IDB or in-memory fake. */
export interface SnapbackStoreOps {
  /** Un-acked segments ascending by seqId. */
  listUnacked(): Promise<Segment[]>;
  /** Delete the given seqIds; resolve to the number actually deleted. */
  deleteSeqIds(seqIds: number[]): Promise<number>;
  /** Reset the ack cursor (seq horizon) to `seq`. */
  setCursor(seq: number): Promise<void>;
}

export interface SnapbackPlan {
  /** seqIds to delete (the un-acked set). */
  purgeSeqIds: number[];
  /** New ack cursor value (= serverHeadSeq). */
  newCursor: number;
  /** State transitions in order. */
  transitions: ["SYNC_REFUSED_BY_SERVER", "READY_STANDALONE"];
}

/** Pure: compute the snapback plan for a refusal at server head `serverHeadSeq`. */
export function planSnapback(
  unackedSegments: Segment[],
  serverHeadSeq: number,
): SnapbackPlan {
  return {
    purgeSeqIds: unackedSegments
      .map((s) => s.seqId)
      .sort((a, b) => a - b),
    newCursor: serverHeadSeq,
    transitions: ["SYNC_REFUSED_BY_SERVER", "READY_STANDALONE"],
  };
}

/**
 * Drive a refusal rollback against the store: list un-acked, purge, reset the
 * cursor, return the plan that was applied.
 */
export async function snapbackWithStore(
  ops: SnapbackStoreOps,
  serverHeadSeq: number,
): Promise<SnapbackPlan & { purged: number }> {
  const unackedSegments = await ops.listUnacked();
  const plan = planSnapback(unackedSegments, serverHeadSeq);
  const purged = plan.purgeSeqIds.length > 0
    ? await ops.deleteSeqIds(plan.purgeSeqIds)
    : 0;
  await ops.setCursor(plan.newCursor);
  return { ...plan, purged };
}
