/**
 * Console blob data-plane client over the smalt emulator (8443 egress plane).
 *
 * Air-gap law: every request rides smaltFetch/assertLocalUrl (lib/smalt.ts) —
 * loopback only, redirect:"error" so a 30x can never carry the request
 * off-host. x-ms-version 2021-12-02 is required by the substrate guard.
 *
 * Auth: smalt STS Bearer (enforce-mode substrate) via stsToken(), or any
 * pre-minted token. The substrate also accepts anonymous mode; a token is
 * simply forwarded when configured.
 *
 * Typed errors: the substrate answers failures with the ARM-style JSON
 * envelope {"error":{code,message}} — surfaced as SmaltStorageError with
 * statusCode / code / message / target / requestId.
 */

import { smaltFetch, assertLocalUrl } from "../../../lib/smalt.js";

export const DEFAULT_BLOB_BASE =
  process.env.NEXT_PUBLIC_SMALT_EGRESS || "http://127.0.0.1:8443";
export const DEFAULT_ARM_BASE =
  process.env.NEXT_PUBLIC_SMALT_ARM || "http://127.0.0.1:9443";
export const SMALT_XMS_VERSION = "2021-12-02";

/** ARM-style typed error envelope over the blob plane. */
export class SmaltStorageError extends Error {
  readonly statusCode: number;
  /** Error code from the envelope, e.g. ContainerLocked / BlobNotFound. */
  readonly code: string;
  readonly message: string;
  readonly target?: string;
  readonly requestId?: string;

  constructor(
    statusCode: number,
    code: string,
    message: string,
    opts: { target?: string; requestId?: string } = {},
  ) {
    super(`[${statusCode} ${code}] ${message}`);
    this.name = "SmaltStorageError";
    this.statusCode = statusCode;
    this.code = code;
    this.message = message;
    this.target = opts.target;
    this.requestId = opts.requestId;
  }
}

/** Mint a Bearer token from the smalt STS (any client_id/secret accepted). */
export async function stsToken(
  armBase: string = DEFAULT_ARM_BASE,
  tenant = "organizations",
): Promise<string> {
  const res = await smaltFetch(armBase, `/${tenant}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "smalt-console",
      client_secret: "smalt-console",
    }).toString(),
  });
  if (!res.ok) {
    throw new SmaltStorageError(res.status, "AuthenticationFailed", `STS token request failed (HTTP ${res.status})`);
  }
  const body = (await res.json()) as { access_token?: string };
  if (!body.access_token) throw new SmaltStorageError(res.status, "AuthenticationFailed", "STS returned no access_token");
  return body.access_token;
}

/** Wire-safe path segments (container / blob names, slash-joined for blobs). */
function enc(segment: string): string {
  return encodeURIComponent(segment);
}

export interface SmaltBlobClientOptions {
  /** Egress base, default http://127.0.0.1:8443 (loopback only). */
  base?: string;
  account?: string;
  /** Pre-minted STS Bearer token (enforce mode). */
  token?: string;
  /** Token provider; preferred over `token` for long-lived clients. */
  getToken?: () => Promise<string>;
  version?: string;
}

export interface BlobResponse {
  status: number;
  etag?: string;
  /** Snapshot timestamp (x-ms-snapshot) when the op created one. */
  snapshot?: string;
  headers: Record<string, string>;
  body: Buffer;
}

export class SmaltBlobClient {
  readonly base: string;
  readonly account: string;
  private readonly version: string;
  private readonly token?: string;
  private readonly getToken?: () => Promise<string>;

  constructor(opts: SmaltBlobClientOptions = {}) {
    this.base = opts.base ?? DEFAULT_BLOB_BASE;
    // assertLocalUrl at construction: a misconfigured base fails fast.
    assertLocalUrl(this.base);
    this.account = opts.account ?? "smaltacct";
    this.version = opts.version ?? SMALT_XMS_VERSION;
    this.token = opts.token;
    this.getToken = opts.getToken;
  }

  /** smaltFetch with the mandatory x-ms-version + optional Bearer. */
  private async req(
    method: string,
    path: string,
    init: RequestInit = {},
    extra: Record<string, string> = {},
  ): Promise<BlobResponse> {
    const headers: Record<string, string> = {
      "x-ms-version": this.version,
      ...extra,
      ...(init.headers as Record<string, string> | undefined),
    };
    const tok = this.token ?? (this.getToken ? await this.getToken() : undefined);
    if (tok) headers["authorization"] = `Bearer ${tok}`;

    const res = await smaltFetch(this.base, path, { ...init, method, headers });
    const body = Buffer.from(await res.arrayBuffer());
    const hdrs: Record<string, string> = {};
    res.headers.forEach((v, k) => {
      hdrs[k] = v;
    });
    if (!res.ok) {
      throw new SmaltStorageError(
        res.status,
        hdrs["x-ms-error-code"] || parseErrorCode(body),
        parseErrorMessage(body) || `HTTP ${res.status}`,
        { requestId: hdrs["x-ms-request-id"] },
      );
    }
    return {
      status: res.status,
      etag: hdrs["etag"],
      snapshot: hdrs["x-ms-snapshot"],
      headers: hdrs,
      body,
    };
  }

  // -- containers -----------------------------------------------------------

  /**
   * Put Container (restype=container). 201 created, 409 already exists.
   *
   * Substrate extension: the egress default containers are WORM-immutable;
   * pass `immutable: false` to send `x-ms-immutable-policy: false` and opt
   * out (the same opt-out the SDK smoke tier uses).
   */
  createContainer(
    name: string,
    opts: { metadata?: Record<string, string>; immutable?: boolean } = {},
  ): Promise<BlobResponse> {
    return this.req("PUT", `/${this.account}/${enc(name)}?restype=container`, {
      headers: {
        ...(opts.immutable === false ? { "x-ms-immutable-policy": "false" } : {}),
        ...metaToHeaders(opts.metadata),
      },
    });
  }

  /** Delete Container. */
  deleteContainer(name: string): Promise<BlobResponse> {
    return this.req("DELETE", `/${this.account}/${enc(name)}?restype=container`);
  }

  /** Get Container Properties (HEAD). */
  headContainer(name: string): Promise<BlobResponse> {
    return this.req("HEAD", `/${this.account}/${enc(name)}?restype=container`);
  }

  /** List Containers (GET ?comp=list) — parsed <Name> entries. */
  async listContainers(): Promise<string[]> {
    const res = await this.req("GET", `/${this.account}/?comp=list`);
    return [...res.body.toString("utf8").matchAll(/<Name>([^<]+)<\/Name>/g)].map((m) => m[1]);
  }

  /** Get Container Metadata (GET ?comp=metadata). */
  async getContainerMetadata(name: string): Promise<Record<string, string>> {
    const res = await this.req("GET", `/${this.account}/${enc(name)}?restype=container&comp=metadata`);
    return headersToMeta(res.headers);
  }

  /** Set Container Metadata (PUT ?comp=metadata, x-ms-meta-*). */
  setContainerMetadata(name: string, metadata: Record<string, string>): Promise<BlobResponse> {
    return this.req("PUT", `/${this.account}/${enc(name)}?restype=container&comp=metadata`, {
      headers: metaToHeaders(metadata),
    });
  }

  /** Set Container ACL-ish legal hold (PUT ?comp=legalhold, x-ms-legal-hold). */
  setLegalHold(name: string, flag: boolean): Promise<BlobResponse> {
    return this.req("PUT", `/${this.account}/${enc(name)}?restype=container&comp=legalhold`, {
      headers: { "x-ms-legal-hold": String(flag) },
    });
  }

  /** Set/lock the immutability policy (PUT ?comp=immutabilityPolicy). */
  async setImmutabilityPolicy(
    name: string,
    policy: { immutabilityPeriodSinceCreationInDays?: number; expiresOn?: string; locked?: boolean; ifMatch?: string },
  ): Promise<BlobResponse & { record: Record<string, unknown> }> {
    const headers: Record<string, string> = {};
    if (policy.ifMatch) headers["if-match"] = policy.ifMatch;
    const res = await this.req(
      "PUT",
      `/${this.account}/${enc(name)}?restype=container&comp=immutabilityPolicy`,
      {
        headers,
        body: JSON.stringify({
          ...(policy.immutabilityPeriodSinceCreationInDays !== undefined
            ? { immutabilityPeriodSinceCreationInDays: policy.immutabilityPeriodSinceCreationInDays }
            : {}),
          ...(policy.expiresOn ? { expiresOn: policy.expiresOn } : {}),
          ...(policy.locked !== undefined ? { locked: policy.locked } : {}),
        }),
      },
    );
    const record = (tryJson(res.body) ?? {}) as Record<string, unknown>;
    return { ...res, record };
  }

  // -- blobs ----------------------------------------------------------------

  /** Put Blob (x-ms-blob-type: BlockBlob) — full upload, 201. */
  uploadBlockBlob(
    container: string,
    blob: string,
    content: Buffer,
    opts: { metadata?: Record<string, string>; contentType?: string; ifMatch?: string } = {},
  ): Promise<BlobResponse> {
    const headers: Record<string, string> = {
      "x-ms-blob-type": "BlockBlob",
      ...metaToHeaders(opts.metadata),
      ...(opts.contentType ? { "content-type": opts.contentType } : {}),
      ...(opts.ifMatch ? { "if-match": opts.ifMatch } : {}),
    };
    return this.req("PUT", `/${this.account}/${enc(container)}/${blobPath(blob)}`, { headers, body: new Uint8Array(content) });
  }

  /** Put Block — stage one block (PUT ?comp=block&blockid=...). */
  putBlock(container: string, blob: string, blockId: string, content: Buffer): Promise<BlobResponse> {
    return this.req(
      "PUT",
      `/${this.account}/${enc(container)}/${blobPath(blob)}?comp=block&blockid=${encodeURIComponent(blockId)}`,
      { headers: { "x-ms-blob-type": "BlockBlob" }, body: new Uint8Array(content) },
    );
  }

  /** Put Block List — commit staged blocks in order (PUT ?comp=blocklist). */
  putBlockList(container: string, blob: string, blockIds: string[]): Promise<BlobResponse> {
    const xml =
      `<?xml version="1.0" encoding="utf-8"?><BlockList>` +
      blockIds.map((id) => `<Latest>${id}</Latest>`).join("") +
      `</BlockList>`;
    return this.req("PUT", `/${this.account}/${enc(container)}/${blobPath(blob)}?comp=blocklist`, {
      headers: { "x-ms-blob-type": "BlockBlob", "content-type": "application/xml" },
      body: new Uint8Array(Buffer.from(xml, "utf8")),
    });
  }

  /** Get Blob — full body, byte-exact. Supports ?snapshot= for a snapshot read. */
  downloadBlob(container: string, blob: string, opts: { snapshot?: string } = {}): Promise<BlobResponse> {
    const q = opts.snapshot ? `?snapshot=${encodeURIComponent(opts.snapshot)}` : "";
    return this.req("GET", `/${this.account}/${enc(container)}/${blobPath(blob)}${q}`);
  }

  /** Get Blob Metadata (GET ?comp=metadata). */
  async getBlobMetadata(container: string, blob: string): Promise<Record<string, string>> {
    const res = await this.req("GET", `/${this.account}/${enc(container)}/${blobPath(blob)}?comp=metadata`);
    return headersToMeta(res.headers);
  }

  /** Set Blob Metadata (PUT ?comp=metadata). */
  setBlobMetadata(container: string, blob: string, metadata: Record<string, string>): Promise<BlobResponse> {
    return this.req("PUT", `/${this.account}/${enc(container)}/${blobPath(blob)}?comp=metadata`, {
      headers: metaToHeaders(metadata),
    });
  }

  /** Head Blob — existence, etag, metadata. 404 BlobNotFound when missing. */
  headBlob(container: string, blob: string): Promise<BlobResponse> {
    return this.req("HEAD", `/${this.account}/${enc(container)}/${blobPath(blob)}`);
  }

  /** Snapshot Blob (PUT ?comp=snapshot) — returns x-ms-snapshot. */
  createSnapshot(container: string, blob: string): Promise<BlobResponse> {
    return this.req("PUT", `/${this.account}/${enc(container)}/${blobPath(blob)}?comp=snapshot`);
  }

  /** Delete Blob (DELETE). 202 on success; 409 ContainerLocked under WORM. */
  deleteBlob(container: string, blob: string, opts: { snapshot?: string } = {}): Promise<BlobResponse> {
    const q = opts.snapshot ? `?snapshot=${encodeURIComponent(opts.snapshot)}` : "";
    return this.req("DELETE", `/${this.account}/${enc(container)}/${blobPath(blob)}${q}`);
  }
}

// -- helpers ------------------------------------------------------------------

function blobPath(blob: string): string {
  return blob.split("/").map(enc).join("/");
}

function metaToHeaders(metadata?: Record<string, string>): Record<string, string> | undefined {
  if (!metadata) return undefined;
  return Object.fromEntries(Object.entries(metadata).map(([k, v]) => [`x-ms-meta-${k}`, v]));
}

function headersToMeta(headers: Record<string, string>): Record<string, string> {
  return Object.fromEntries(
    Object.entries(headers)
      .filter(([k]) => k.startsWith("x-ms-meta-"))
      .map(([k, v]) => [k.slice("x-ms-meta-".length), v]),
  );
}

function parseErrorCode(body: Buffer): string {
  const json = tryJson(body);
  if (json) {
    const err = (json as { error?: { code?: string } }).error;
    if (err?.code) return err.code;
  }
  const xml = body.toString("utf8").match(/<Code>([^<]+)<\/Code>/);
  return xml ? xml[1] : "UnknownError";
}

function parseErrorMessage(body: Buffer): string | undefined {
  const json = tryJson(body);
  if (json) {
    const err = (json as { error?: { message?: string } }).error;
    if (err?.message) return err.message;
  }
  const xml = body.toString("utf8").match(/<Message>([^<]+)<\/Message>/);
  return xml ? xml[1] : undefined;
}

function tryJson(body: Buffer): unknown {
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    return undefined;
  }
}
