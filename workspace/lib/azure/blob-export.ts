/**
 * WORM receipt export — the air-gap export simulation.
 *
 * Targets the smalt egress blob plane (NEXT_PUBLIC_SMALT_EGRESS, default
 * http://127.0.0.1:8443), account `smaltacct`. The substrate's egress default
 * is an immutable (WORM) container: once a blob lands, an overwrite attempt
 * is rejected with 409. That rejection IS the export guarantee — a
 * session-ledger receipt bundle written once cannot be rewritten in place.
 *
 * Auth shape (witnessed against the emulator, mirroring
 * test/sdk-smoke/blob.test.cjs): StorageSharedKeyCredential request signing
 * on plain HTTP. Storage OAuth (Bearer) requires https and the smalt STS
 * Bearer cannot be injected on a plain-HTTP storage endpoint, so the
 * enforce-mode Bearer contract is covered server-side by
 * test/auth_enforce_test.exs — not here.
 */

import type { BlobServiceClient, BlockBlobClient } from "@azure/storage-blob";

/** Default egress endpoint for the local smalt substrate. */
export const DEFAULT_EGRESS =
  process.env.NEXT_PUBLIC_SMALT_EGRESS || "http://127.0.0.1:8443";

export const BLOB_ACCOUNT = "smaltacct";
export const BLOB_ACCOUNT_KEY = "smaltacct-key";

/** A session-ledger receipt bundle destined for immutable export. */
export interface ReceiptBundle {
  /** Session id; also the container suffix (lowercased for Azure naming). */
  sessionId: string;
  /** The receipt records themselves (JSON-serializable). */
  receipts: Array<Record<string, unknown>>;
  /** Optional extra metadata stamped on every blob. */
  metadata?: Record<string, string>;
}

export interface ExportResult {
  containerName: string;
  bundleBlobName: string;
  manifestBlobName: string;
  /** HTTP status of the bundle upload (201 on first write). */
  uploadStatus: number;
  /**
   * True when the overwrite attempt was rejected with 409 — the WORM
   * guarantee witnessed on the wire.
   */
  overwriteRejected: boolean;
  /** HTTP status of the overwrite attempt (409 expected under WORM). */
  overwriteStatus: number | undefined;
  /** ETag of the first (only) accepted write. */
  etag: string | undefined;
}

/** WORM overwrite rejection, surfaced for callers that expect immutability. */
export class ImmutableOverwriteError extends Error {
  readonly statusCode: number;
  constructor(statusCode: number) {
    super(`WORM: overwrite of immutable receipt blob rejected (HTTP ${statusCode})`);
    this.name = "ImmutableOverwriteError";
    this.statusCode = statusCode;
  }
}

const T = (ms: number) => AbortSignal.timeout(ms);

/**
 * Build the canonical immutable container name for a session ledger:
 * `receipts-<lowercased sessionId>`. Exported for probe/receipt citation.
 */
export function receiptContainerName(sessionId: string): string {
  return `receipts-${sessionId.toLowerCase()}`;
}

/**
 * Export a session-ledger receipt bundle:
 * 1. create the (immutable-by-default) container,
 * 2. upload the bundle + a small export manifest,
 * 3. re-upload the bundle blob to prove the WORM 409.
 *
 * @throws ImmutableOverwriteError if the overwrite unexpectedly SUCCEEDS
 * (container not immutable) — fail-closed, never a silent rewrite.
 */
export async function exportReceiptBundle(
  service: BlobServiceClient,
  bundle: ReceiptBundle,
  opts: { timeoutMs?: number } = {},
): Promise<ExportResult> {
  const timeoutMs = opts.timeoutMs ?? 60_000;
  const containerName = receiptContainerName(bundle.sessionId);
  const container = service.getContainerClient(containerName);
  await container.create({ abortSignal: T(timeoutMs) });

  const blob: BlockBlobClient = container.getBlockBlobClient("receipt-bundle.json");
  const payload = Buffer.from(JSON.stringify(bundle.receipts), "utf8");
  const up = await blob.upload(payload, payload.length, {
    metadata: bundle.metadata,
    abortSignal: T(timeoutMs),
  });

  const manifestBlob = container.getBlockBlobClient("export-manifest.json");
  const manifest = Buffer.from(
    JSON.stringify({
      sessionId: bundle.sessionId,
      exportedAt: new Date().toISOString(),
      receiptCount: bundle.receipts.length,
      bundleBlob: blob.name,
      etag: up.etag,
    }),
    "utf8",
  );
  await manifestBlob.upload(manifest, manifest.length, { abortSignal: T(timeoutMs) });

  // The air-gap export simulation: the second write MUST be rejected.
  try {
    await blob.upload(Buffer.from("tamper", "utf8"), 6, { abortSignal: T(timeoutMs) });
  } catch (err: unknown) {
    const status = (err as { statusCode?: number }).statusCode;
    if (status === 409) {
      return {
        containerName,
        bundleBlobName: blob.name,
        manifestBlobName: manifestBlob.name,
        uploadStatus: up._response.status,
        overwriteRejected: true,
        overwriteStatus: status,
        etag: up.etag,
      };
    }
    throw err;
  }
  // Overwrite succeeded — the container is NOT immutable. Fail closed.
  throw new ImmutableOverwriteError(200);
}
