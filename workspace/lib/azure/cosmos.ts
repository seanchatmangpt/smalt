/**
 * Raw-wire Cosmos NoSQL client for the smalt workspace console.
 *
 * Transport is smaltFetch (lib/smalt.ts) exclusively — the air-gap guard
 * (assertLocalUrl) validates every URL, and the redirect:"error" posture
 * (SHIM-COURT marker in lib/smalt.ts) keeps a 30x from carrying the request
 * off-host. No @azure/cosmos dependency: the wire shape this client speaks is
 * exactly what the smalt data plane serves (witnessed: lib/smalt/data_plane/
 * cosmos.ex + egress_router.ex; wire proven by test/sdk-full/cosmos.probe.mjs).
 *
 * SEMANTIC PINS (do not "fix"):
 * - CREATE via POST /dbs/:db/colls/:coll/docs; PUT /docs/:id is REPLACE-only
 *   and answers 404 on a missing id (never upsert).
 * - Query POSTs carry content-type application/query+json and
 *   x-ms-documentdb-isquery — the router routes them to the query engine
 *   BEFORE the create handler is reachable (a query POST never creates).
 * - Query SQL is whitelist-enforced substrate-side: `SELECT * FROM <alias>`
 *   only. Anything else (WHERE, ORDER BY, projections) answers a typed 400
 *   SyntaxError — GAP(cosmos-sql-translator-absent). This client surfaces
 *   that as a typed SmaltCosmosError with code "SyntaxError"; it never
 *   retries or papers over the refusal.
 * - Continuation tokens: x-ms-continuation request header on resume, response
 *   header on truncation; the last page carries NO token (row-18 semantics).
 * - Throughput management: the substrate has NO offers/throughput surface —
 *   getThroughput/updateThroughput throw a typed SmaltCosmosGapError
 *   (loud, never a faked success).
 */

import { smaltFetch } from "../smalt";

/** Default egress (data-plane) base for the local smalt substrate. */
export const COSMOS_EGRESS_BASE =
  process.env.NEXT_PUBLIC_SMALT_EGRESS || "http://127.0.0.1:8443";

/** ARM plane base — used for STS token minting in enforce mode. */
export const COSMOS_ARM_BASE =
  process.env.NEXT_PUBLIC_SMALT_ARM || "http://127.0.0.1:9443";

export interface SmaltCosmosConfig {
  /** Data-plane base (docs/query routes), e.g. http://127.0.0.1:8443. */
  egressBase?: string;
  /**
   * Bearer token (enforce mode) or an async provider. Omit for an
   * anonymous-mode substrate.
   */
  bearerToken?: string | (() => string | Promise<string>);
  /** ARM plane base for STS minting (defaults to COSMOS_ARM_BASE). */
  armBase?: string;
  /** STS tenant / client creds — the emulator accepts arbitrary values. */
  tenant?: string;
  clientId?: string;
  clientSecret?: string;
}

/** Typed wire error: status + Cosmos error code + body. */
export class SmaltCosmosError extends Error {
  readonly status: number;
  readonly code: string;
  readonly body: unknown;

  constructor(status: number, code: string, body: unknown) {
    super(
      `cosmos ${status} ${code}: ${typeof body === "string" ? body : JSON.stringify(body)}`,
    );
    this.name = "SmaltCosmosError";
    this.status = status;
    this.code = code;
    this.body = body;
  }
}

/**
 * Typed capability gap: the substrate does not implement this surface at all
 * (registered GAP, loud — never a silent faked success).
 */
export class SmaltCosmosGapError extends Error {
  readonly gap: string;

  constructor(gap: string, detail: string) {
    super(`GAP(${gap}): ${detail}`);
    this.name = "SmaltCosmosGapError";
    this.gap = gap;
  }
}

export interface CosmosQueryPage {
  documents: Record<string, unknown>[];
  count: number;
  /** Continuation token for the NEXT page; undefined on the last page. */
  continuation?: string;
  requestCharge?: number;
}

export class SmaltCosmosClient {
  private readonly egressBase: string;
  private readonly armBase: string;
  private readonly cfg: SmaltCosmosConfig;

  constructor(cfg: SmaltCosmosConfig = {}) {
    this.egressBase = (cfg.egressBase ?? COSMOS_EGRESS_BASE).replace(/\/+$/, "");
    this.armBase = (cfg.armBase ?? COSMOS_ARM_BASE).replace(/\/+$/, "");
    this.cfg = cfg;
  }

  /** Mint a bearer token from the smalt STS (client_credentials). */
  async mintToken(tenant = this.cfg.tenant ?? "smalt-tenant"): Promise<string> {
    const res = await smaltFetch(
      this.armBase,
      `/${tenant}/oauth2/v2.0/token`,
      {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "client_credentials",
          client_id: this.cfg.clientId ?? "workspace-console",
          client_secret: this.cfg.clientSecret ?? "workspace-secret",
        }).toString(),
      },
    );
    if (!res.ok) {
      throw new SmaltCosmosError(res.status, "AuthenticationFailed", await res.text());
    }
    const body = (await res.json()) as { access_token: string };
    return body.access_token;
  }

  private async authHeader(): Promise<Record<string, string>> {
    const t = this.cfg.bearerToken;
    if (!t) return {};
    const token = typeof t === "function" ? await t() : t;
    return { authorization: `Bearer ${token}` };
  }

  private async request(
    method: string,
    path: string,
    init?: RequestInit,
  ): Promise<Response> {
    return smaltFetch(this.egressBase, path, {
      ...init,
      headers: { ...(await this.authHeader()), ...(init?.headers ?? {}) },
    });
  }

  private async jsonOrThrow(res: Response): Promise<unknown> {
    const text = await res.text();
    let body: unknown = text;
    try {
      body = JSON.parse(text);
    } catch {
      /* keep raw text */
    }
    if (!res.ok) {
      // Wire shapes witnessed: flat {"code","message"} on the Cosmos plane and
      // nested {"error":{"code",...}} elsewhere — accept both.
      const code =
        (typeof body === "object" && body !== null && "code" in body
          ? String((body as { code?: unknown }).code)
          : undefined) ??
        (typeof body === "object" && body !== null && "error" in body
          ? ((body as { error?: { code?: string } }).error?.code ?? "Unknown")
          : "Unknown");
      throw new SmaltCosmosError(res.status, code || "Unknown", body);
    }
    return body;
  }

  // -- Account -------------------------------------------------------------

  /** GET / — account bootstrap envelope. */
  async account(): Promise<Record<string, unknown>> {
    const res = await this.request("GET", "/");
    return (await this.jsonOrThrow(res)) as Record<string, unknown>;
  }

  // -- Databases / containers ----------------------------------------------

  async listDatabases(): Promise<Record<string, unknown>[]> {
    const res = await this.request("GET", "/dbs");
    const body = (await this.jsonOrThrow(res)) as {
      Databases?: Record<string, unknown>[];
    };
    return body.Databases ?? [];
  }

  /** POST /dbs — create a database. */
  async createDatabase(id: string): Promise<Record<string, unknown>> {
    const res = await this.request("POST", "/dbs", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id }),
    });
    return (await this.jsonOrThrow(res)) as Record<string, unknown>;
  }

  async listContainers(db: string): Promise<Record<string, unknown>[]> {
    const res = await this.request("GET", `/dbs/${db}/colls`);
    const body = (await this.jsonOrThrow(res)) as {
      DocumentCollections?: Record<string, unknown>[];
    };
    return body.DocumentCollections ?? [];
  }

  /** POST /dbs/:db/colls — create a container with partition key path(s). */
  async createContainer(
    db: string,
    id: string,
    pkPaths: string[] = ["/pk"],
  ): Promise<Record<string, unknown>> {
    const res = await this.request("POST", `/dbs/${db}/colls`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id, partitionKey: { paths: pkPaths } }),
    });
    return (await this.jsonOrThrow(res)) as Record<string, unknown>;
  }

  // -- Documents -------------------------------------------------------------

  /** POST-create a document. `pk` is the RAW partition value. */
  async createDoc(
    db: string,
    coll: string,
    doc: Record<string, unknown>,
    opts: { pk?: string; upsert?: boolean } = {},
  ): Promise<{ status: number; doc: Record<string, unknown> }> {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (opts.pk !== undefined) {
      headers["x-ms-documentdb-partitionkey"] = JSON.stringify([opts.pk]);
    }
    if (opts.upsert) headers["x-ms-documentdb-is-upsert"] = "true";
    const res = await this.request("POST", `/dbs/${db}/colls/${coll}/docs`, {
      method: "POST",
      headers,
      body: JSON.stringify(doc),
    });
    const body = (await this.jsonOrThrow(res)) as Record<string, unknown>;
    return { status: res.status, doc: body };
  }

  async getDoc(
    db: string,
    coll: string,
    id: string,
    pk?: string,
  ): Promise<Record<string, unknown>> {
    const res = await this.request(
      "GET",
      `/dbs/${db}/colls/${coll}/docs/${encodeURIComponent(id)}`,
      { headers: pk ? { "x-ms-documentdb-partitionkey": JSON.stringify([pk]) } : undefined },
    );
    return (await this.jsonOrThrow(res)) as Record<string, unknown>;
  }

  /** PUT /docs/:id — REPLACE-only (404 on missing id; never an upsert). */
  async replaceDoc(
    db: string,
    coll: string,
    id: string,
    doc: Record<string, unknown>,
    pk?: string,
  ): Promise<Record<string, unknown>> {
    const res = await this.request(
      "PUT",
      `/dbs/${db}/colls/${coll}/docs/${encodeURIComponent(id)}`,
      {
        method: "PUT",
        headers: {
          "content-type": "application/json",
          ...(pk ? { "x-ms-documentdb-partitionkey": JSON.stringify([pk]) } : {}),
        },
        body: JSON.stringify(doc),
      },
    );
    return (await this.jsonOrThrow(res)) as Record<string, unknown>;
  }

  async deleteDoc(
    db: string,
    coll: string,
    id: string,
    pk?: string,
  ): Promise<{ status: number }> {
    const res = await this.request(
      "DELETE",
      `/dbs/${db}/colls/${coll}/docs/${encodeURIComponent(id)}`,
      { headers: pk ? { "x-ms-documentdb-partitionkey": JSON.stringify([pk]) } : undefined },
    );
    await this.jsonOrThrow(res);
    return { status: res.status };
  }

  // -- Query feed --------------------------------------------------------------

  /**
   * One query page. `pk` is the RAW partition value (JSON-wrapped into the
   * x-ms-documentdb-partitionkey header); `continuation` resumes the feed.
   */
  async query(
    db: string,
    coll: string,
    sql: string,
    opts: { pk?: string; continuation?: string } = {},
  ): Promise<CosmosQueryPage> {
    const headers: Record<string, string> = {
      "content-type": "application/query+json",
      "x-ms-documentdb-isquery": "true",
    };
    if (opts.pk !== undefined) {
      headers["x-ms-documentdb-partitionkey"] = JSON.stringify([opts.pk]);
    }
    if (opts.continuation !== undefined) headers["x-ms-continuation"] = opts.continuation;
    const res = await this.request("POST", `/dbs/${db}/colls/${coll}/docs`, {
      method: "POST",
      headers,
      body: JSON.stringify({ query: sql }),
    });
    const body = (await this.jsonOrThrow(res)) as {
      Documents?: Record<string, unknown>[];
      _count?: number;
    };
    return {
      documents: body.Documents ?? [],
      count: body._count ?? 0,
      continuation: res.headers.get("x-ms-continuation") ?? undefined,
      requestCharge: Number(res.headers.get("x-ms-request-charge") ?? 0),
    };
  }

  /** Walk the continuation feed to exhaustion; returns every document. */
  async queryAll(
    db: string,
    coll: string,
    sql: string,
    opts: { pk?: string } = {},
  ): Promise<Record<string, unknown>[]> {
    const out: Record<string, unknown>[] = [];
    let continuation: string | undefined;
    let pages = 0;
    do {
      const page = await this.query(db, coll, sql, { ...opts, continuation });
      out.push(...page.documents);
      continuation = page.continuation;
      pages++;
      if (pages > 1000) throw new Error("continuation walk exceeded 1000 pages — runaway feed");
    } while (continuation);
    return out;
  }

  // -- Partition-key ranges / throughput ---------------------------------------

  /** GET /dbs/:db/colls/:coll/pkranges — partition-key-range feed. */
  async listPartitionKeyRanges(db: string, coll: string): Promise<Record<string, unknown>[]> {
    const res = await this.request("GET", `/dbs/${db}/colls/${coll}/pkranges`);
    const body = (await this.jsonOrThrow(res)) as {
      PartitionKeyRanges?: Record<string, unknown>[];
    };
    return body.PartitionKeyRanges ?? [];
  }

  /**
   * Typed gap: the substrate has NO offers/throughput surface. Loud refusal,
   * never a faked success.
   */
  async getThroughput(_db: string, _coll: string): Promise<never> {
    throw new SmaltCosmosGapError(
      "cosmos-throughput-absent",
      "the substrate exposes no offers/throughput surface",
    );
  }

  async updateThroughput(_db: string, _coll: string, _ru: number): Promise<never> {
    throw new SmaltCosmosGapError(
      "cosmos-throughput-absent",
      "the substrate exposes no offers/throughput surface",
    );
  }
}
