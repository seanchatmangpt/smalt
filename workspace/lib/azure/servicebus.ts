/**
 * Service Bus data-plane client for the smalt console (lane 522).
 *
 * Two planes, both loopback-only:
 *  - ARM control plane (http://127.0.0.1:9443): namespace/queue/topic/
 *    subscription CRUD; bearer minted from the local STS
 *    (POST /{tenant}/oauth2/v2.0/token); every URL rides smaltFetch so the
 *    air-gap guard (assertLocalUrl) fences it.
 *  - AMQP broker (sb://127.0.0.1:5672): send/receive via the real
 *    @azure/service-bus SDK (SASL ANONYMOUS + CBS, emulator conn-str). The
 *    console is HTTP-only; no HTTP message face exists on the broker
 *    (zero message routes in lib/smalt/arm_gateway/router.ex, witnessed by
 *    grep pre-write), so the SDK is the thin AMQP client.
 *
 * Substrate routes witnessed pre-write:
 *   lib/smalt/arm_gateway/router.ex — PUT/GET/DELETE .../namespaces/.../
 *   queues|topics|subscriptions
 *   lib/smalt/messaging/amqp/* — QueueStore send/receive/lock/DLQ.
 */

import { smaltFetch } from "../smalt.js"; // .js specifier: resolves cleanly without allowImportingTsExtensions
import { ServiceBusClient } from "@azure/service-bus";

const DEFAULT_SUB = "00000000-0000-0000-0000-000000000000";
const API_VERSION = "2021-04-01";

/** Emulator connection string for the @azure/service-bus SDK. */
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

export interface ServiceBusDataplaneOptions {
  armBase?: string;
  amqpPort?: number;
  sharedKey?: string;
  tenant?: string;
  subscriptionId?: string;
  resourceGroup?: string;
  namespace?: string;
}

/** Typed error envelope surfaced to console callers. */
export class ServiceBusDataplaneError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(`[${status}] ${code}: ${message}`);
    this.name = "ServiceBusDataplaneError";
    this.status = status;
    this.code = code;
  }
}

interface ArmEnvelope {
  error?: { code?: unknown };
}

function envelopeCode(status: number, body: unknown): string {
  const code = (body as ArmEnvelope | null)?.error?.code;
  return typeof code === "string" && code ? code : `HTTP_${status}`;
}

/** ARM CRUD + AMQP messaging facade. Loopback only. */
export class ServiceBusDataplane {
  readonly namespace: string;
  private readonly armBase: string;
  private readonly sub: string;
  private readonly rg: string;
  private readonly tenant: string;
  private readonly amqpPort: number;
  private readonly sharedKey: string;
  private token: { token: string; expiresOnTimestamp: number } | null = null;
  private client: ServiceBusClient | null = null;

  constructor(opts: ServiceBusDataplaneOptions = {}) {
    this.armBase = opts.armBase ?? "http://127.0.0.1:9443";
    this.amqpPort = opts.amqpPort ?? 5672;
    this.sharedKey = opts.sharedKey ?? Buffer.from("ws8sharedkey").toString("base64");
    this.tenant = opts.tenant ?? "dev";
    this.sub = opts.subscriptionId ?? DEFAULT_SUB;
    this.rg = opts.resourceGroup ?? "console-rg";
    this.namespace = opts.namespace ?? "console-ns";
  }

  /** Mint (and cache) a bearer token from the local STS. */
  async authorize(): Promise<string> {
    if (this.token && Date.now() < this.token.expiresOnTimestamp - 60_000) {
      return this.token.token;
    }
    const res = await smaltFetch(this.armBase, `/${this.tenant}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: "servicebus-dataplane",
        client_secret: "console",
        scope: "https://management.azure.com/.default",
      }).toString(),
      redirect: "error",
    });
    if (!res.ok) {
      throw new ServiceBusDataplaneError(res.status, "STS_MINT_FAILED", `mint -> ${res.status}`);
    }
    const json = (await res.json()) as { access_token?: unknown };
    if (typeof json.access_token !== "string") {
      throw new ServiceBusDataplaneError(500, "STS_MINT_FAILED", "access_token missing");
    }
    this.token = { token: json.access_token, expiresOnTimestamp: Date.now() + 3_600_000 };
    return this.token.token;
  }

  private async armRequest(
    method: string,
    pathSuffix: string,
    body?: unknown,
  ): Promise<{ status: number; json: unknown }> {
    const token = await this.authorize();
    const res = await smaltFetch(
      this.armBase,
      `/subscriptions/${this.sub}/resourceGroups/${this.rg}/providers/` +
        `Microsoft.ServiceBus/namespaces/${this.namespace}${pathSuffix}` +
        `${pathSuffix.includes("?") ? "&" : "?"}api-version=${API_VERSION}`,
      {
        method,
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(30_000),
      },
    );
    const text = await res.text();
    let json: unknown = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = { raw: text.slice(0, 400) };
    }
    return { status: res.status, json };
  }

  private static ok(status: number, json: unknown): unknown {
    if (status < 200 || status >= 300) {
      throw new ServiceBusDataplaneError(
        status,
        envelopeCode(status, json),
        JSON.stringify(json ?? null).slice(0, 300),
      );
    }
    return json;
  }

  /** Create (idempotent PUT) the namespace. */
  async createNamespace(): Promise<unknown> {
    const r = await this.armRequest("PUT", "", { location: "smalt", skuName: "Standard" });
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** PUT a queue with camelCase SB properties. */
  async createQueue(name: string, properties: Record<string, unknown> = {}): Promise<unknown> {
    const r = await this.armRequest("PUT", `/queues/${name}`, { location: "smalt", properties });
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** GET a queue; typed 404 error if absent. */
  async getQueue(name: string): Promise<unknown> {
    const r = await this.armRequest("GET", `/queues/${name}`);
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** GET the queue feed. */
  async listQueues(): Promise<unknown> {
    const r = await this.armRequest("GET", "/queues");
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** DELETE a queue. */
  async deleteQueue(name: string): Promise<unknown> {
    const r = await this.armRequest("DELETE", `/queues/${name}`);
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** PUT a topic. */
  async createTopic(name: string): Promise<unknown> {
    const r = await this.armRequest("PUT", `/topics/${name}`, { location: "smalt", skuName: "Standard" });
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** GET a topic. */
  async getTopic(name: string): Promise<unknown> {
    const r = await this.armRequest("GET", `/topics/${name}`);
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** PUT a subscription under a topic. */
  async createSubscription(topic: string, name: string): Promise<unknown> {
    const r = await this.armRequest("PUT", `/topics/${topic}/subscriptions/${name}`, {
      location: "smalt",
    });
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** GET a subscription. */
  async getSubscription(topic: string, name: string): Promise<unknown> {
    const r = await this.armRequest("GET", `/topics/${topic}/subscriptions/${name}`);
    return ServiceBusDataplane.ok(r.status, r.json);
  }

  /** Lazily built ServiceBusClient (emulator verifier accepts any base64 key). */
  amqp(): ServiceBusClient {
    if (!this.client) {
      this.client = new ServiceBusClient(sbConnectionString(this.amqpPort, this.sharedKey), {
        retryOptions: { maxRetries: 0, timeoutInMs: 10_000 },
      });
    }
    return this.client;
  }

  async close(): Promise<void> {
    if (this.client) {
      const c = this.client;
      this.client = null;
      await c.close();
    }
  }
}

export { API_VERSION };
