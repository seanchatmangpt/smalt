/**
 * Typed READ-ONLY ARM query wrappers.
 *
 * EXPORT-SURFACE BAN: this module exports only read operations. There is no
 * mutating function in the export list, so any mutating call attempt is a
 * compile-time error ("has no exported member"). SDK-tier mutations, if ever
 * needed, must be routed through lane WS-4's guardedFetch contract
 * (workspace/lib/copilot/session-ledger.ts), which refuses mutation-shaped
 * requests with a typed ZERO_ACTUATION refusal before any network call.
 *
 * Wire contract notes (witnessed, docs/jira/v26.10.14/sdk-results/
 * ts-arm-resources.md):
 *  - listResourceGroups uses GET /subscriptions/{sub}/resourcegroups
 *    (witnessed 200; probe #4).
 *  - listResourcesByRG uses the subscription-level generic resource list
 *    (GET /subscriptions/{sub}/resources) rather than the per-RG route
 *    (/resourcegroups/{rg}/resources) because the per-RG route is missing on
 *    the emulator (divergence D2: 404 RouteNotFound, confirmed raw with curl).
 *  - listSubscriptions uses GET /subscriptions (auth probe #2, 200).
 */
import { getReadOnlyArmClient, SMALT_SUBSCRIPTION_ID, ARM_API_VERSION } from "./arm-client.js";
import type { ArmReadFacade } from "./arm-client.js";
import { ClientSecretCredential } from "@azure/identity";
import { assertLocalUrl } from "../smalt.js"; // SHIM-COURT: air-gap host check before any egress

/** A subscription as returned by GET /subscriptions (arm-subscriptions wire). */
export interface SubscriptionRow {
  subscriptionId: string;
  displayName?: string;
  state?: string;
}

/** An ARM generic resource shape (subset consumed by the console). */
export interface GenericResourceRow {
  id: string;
  name?: string;
  type?: string;
  location?: string;
  provisioningState?: string | null;
}

export interface QueryContext {
  armBase: string;
  tenant?: string;
  clientId?: string;
  queryClientSecret?: string;
  clientSecret?: string;
  /** Injected credential (tests); otherwise built from armBase. */
  credential?: ClientSecretCredential;
  /** Fetch override (tests only). */
  fetchImpl?: typeof fetch;
}

/** The one credential/client the query module uses. Internal. */
let ctx: {
  credential: ClientSecretCredential;
  facade: ArmReadFacade;
  fetchImpl: typeof fetch;
  armBase: string;
} | null = null;

function ensureContext(q?: QueryContext): NonNullable<typeof ctx> {
  if (ctx && !q) return ctx;
  const armBase = q?.armBase ?? globalThisArmBase();
  const fetchImpl = q?.fetchImpl ?? fetch;
  // SHIM-COURT: refuse non-local armBase — it is the msal authorityHost (the
  // only egress ClientSecretCredential makes) and the ARM endpoint.
  assertLocalUrl(armBase);
  const credential =
    q?.credential ??
    new ClientSecretCredential(
      q?.tenant ?? "smalt-tenant",
      q?.clientId ?? "workspace-console",
      q?.clientSecret ?? q?.queryClientSecret ?? "workspace-secret",
      // authorityHost = ORIGIN (scheme+host+port, no path); msal appends
      // /{tenant}/v2.0/... itself. disableInstanceDiscovery: see arm-client.ts
      // — msal-node queries the real cloud instance endpoint, not the local
      // envelope (witnessed invalid_instance live).
      {
        authorityHost: new URL(armBase).origin,
        disableInstanceDiscovery: true,
      },
    );
  ctx = {
    armBase,
    credential,
    fetchImpl,
    facade: getReadOnlyArmClient({ armBase, tenant: q?.tenant, clientId: q?.clientId, clientSecret: q?.clientSecret }),
  };
  return ctx;
}

function globalThisArmBase(): string {
  const env = (globalThis as { process?: { env?: Record<string, string | undefined> } })
    .process?.env ?? {};
  return env.NEXT_PUBLIC_SMALT_ARM ?? env.SMALT_ARM_BASE ?? "";
}

/** Credentialed GET against the ARM plane (read verbs only, by construction). */
async function armGet(path: string): Promise<unknown> {
  const c = ensureContext();
  const token = await c.credential.getToken("https://management.azure.com/.default");
  // SHIM-COURT: validate the host before any egress (fetchImpl or native).
  assertLocalUrl(`${c.armBase}${path}`);
  const res = await c.fetchImpl(`${c.armBase}${path}`, {
    method: "GET",
    headers: { authorization: `Bearer ${token.token}` },
  });
  if (!res.ok) {
    const body = await res.text();
    const err = new Error(`ARM GET ${path} failed: status=${res.status} body=${body.slice(0, 300)}`);
    (err as Error & { status?: number }).status = res.status;
    throw err;
  }
  return res.json();
}

/** READ: list subscriptions (GET /subscriptions). */
export async function listSubscriptions(): Promise<SubscriptionRow[]> {
  ensureContext();
  const json = (await armGet(`/subscriptions?api-version=${ARM_API_VERSION}`)) as {
    value?: Array<{ subscriptionId?: string; displayName?: string; state?: string }>;
  };
  return (json.value ?? []).map((s) => ({
    subscriptionId: s.subscriptionId ?? "",
    displayName: s.displayName,
    state: s.state,
  }));
}

/** READ: list resource groups (SDK list, GET .../resourcegroups). */
export function listResourceGroups(): Promise<Array<{
  name?: string;
  location?: string;
  provisioningState?: string;
}>> {
  const { facade } = ensureContext();
  return collect(facade.resourceGroups.list());
}

/** READ: generic resource walk (subscription provider inventory). */
export interface ProviderInventory {
  id: string;
  namespace: string;
  subscriptionId: string;
  resourceTypes: Array<Record<string, unknown>>;
}

/**
 * READ: generic resource walk for an RG. The per-RG generic route
 * (/resourcegroups/{rg}/resources) AND the subscription-level generic list
 * (/subscriptions/{sub}/resources) are both missing on the emulator (404
 * RouteNotFound — divergence D2-family, witnessed 2026-10-15 with raw GETs).
 * The witnessed generic read on this emulator is the provider inventory
 * (GET /subscriptions/{sub}/providers, 200). This wrapper returns that
 * inventory (subscription-scoped; `rgName` is not applied server-side because
 * no server-side route can). Callers wanting strict per-RG semantics should
 * use the typed child-list routes on real Azure.
 */
export async function listResourcesByRG(_rgName: string): Promise<ProviderInventory> {
  const sub = SMALT_SUBSCRIPTION_ID;
  const json = (await armGet(
    `/subscriptions/${sub}/providers?api-version=${ARM_API_VERSION}`,
  )) as ProviderInventory;
  return {
    id: json.id ?? "",
    namespace: json.namespace ?? "",
    subscriptionId: json.subscriptionId ?? "",
    resourceTypes: json.resourceTypes ?? [],
  };
}

/**
 * READ: drain an SDK paged-async iterable into an array. The emulated ARM
 * plane pages at 100 items via nextLink; this drains all pages.
 */
async function collect<T>(paged: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const item of paged) out.push(item);
  return out;
}
/**
 * READ: drain an SDK paged-async iterable into an array. The emulated ARM
 * plane pages at 100 items via nextLink; this drains all pages.
 */
