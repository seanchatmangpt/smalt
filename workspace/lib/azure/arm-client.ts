/**
 * Pure-Azure ARM client layer for the smalt workspace console.
 *
 * Builds a real @azure/arm-resources ResourceManagementClient over
 * SmaltTokenCredential, pointed at the smalt ARM emulator (NEXT_PUBLIC_SMALT_ARM),
 * pinned to api-version 2021-04-01 - the emulator is latest-version-only and
 * rejects newer api-versions (400 InvalidApiVersionParameter naming 2021-04-01
 * as the ceiling; witnessed in docs/jira/v26.10.14/sdk-results/ts-arm-resources.md,
 * "api-version ceiling").
 *
 * COMPILE-TIME MUTATION BAN
 * -------------------------
 * This module exports a read-only facade type (`ArmReadFacade`) built with
 * `Pick` of READ operations only. The concrete ResourceManagementClient never
 * escapes this module, so a mutating SDK call (createOrUpdate, beginDeleteById,
 * update, ...) is a compile error in consumer code. Fetch-layer reads are also
 * routed through lane WS-4's guardedFetch contract
 * (workspace/lib/copilot/session-ledger.ts) by the query wrappers.
 */
import { ResourceManagementClient } from "@azure/arm-resources";
import { SmaltTokenCredential } from "./credential.js";

/** api-version pin: emulator ceiling (the emulator is latest-version-only). */
export const ARM_API_VERSION = "2021-04-01";

/** Emulator's fixed subscription id (witnessed: GET /subscriptions returns
 * exactly this one subscription, state=Enabled). */
export const SMALT_SUBSCRIPTION_ID = "00000000-0000-0000-0000-000000000000";

export interface ArmClientConfig {
  armBase: string;
  tenant?: string;
  clientId?: string;
  clientSecret?: string;
}

/** Resolve the ARM base from env. Fails closed when unset. */
export function resolveArmBase(): string {
  const env = (globalThis as { process?: { env?: Record<string, string | undefined> } })
    .process?.env ?? {};
  const base = env.NEXT_PUBLIC_SMALT_ARM ?? env.SMALT_ARM_BASE;
  if (!base) {
    throw new Error("NEXT_PUBLIC_SMALT_ARM (or SMALT_ARM_BASE) is not set");
  }
  return base;
}

let cachedCredential: SmaltTokenCredential | null = null;
let cachedClient: ResourceManagementClient | null = null;

function ensureClient(config?: ArmClientConfig): ResourceManagementClient {
  if (!config && cachedClient && cachedCredential) return cachedClient;
  const armBase = config?.armBase ?? resolveArmBase();
  if (!cachedCredential || config) {
    cachedCredential = new SmaltTokenCredential({
      armBase,
      tenant: config?.tenant,
      clientId: config?.clientId,
      clientSecret: config?.clientSecret,
    });
  }
  if (!cachedClient || config) {
    cachedClient = new ResourceManagementClient(cachedCredential, SMALT_SUBSCRIPTION_ID, {
      endpoint: armBase,
      apiVersion: ARM_API_VERSION,
      allowInsecureConnection: true,
    });
  }
  return cachedClient;
}

/**
 * Read-only facade over ResourceManagementClient: only GET-shaped SDK
 * operations are picked. Mutating methods (createOrUpdate, beginDeleteById,
 * update, ...) are not reachable through this type - any attempt is a
 * compile-time error, enforcing the lane's read-only contract statically.
 */
export interface ArmReadFacade {
  readonly resourceGroups: Pick<
    ResourceManagementClient["resourceGroups"],
    "list" | "get"
  >;
  readonly resources: Pick<
    ResourceManagementClient["resources"],
    "list" | "getById"
  >;
}

/** Get the singleton read-only ARM facade. */
export function getReadOnlyArmClient(config?: ArmClientConfig): ArmReadFacade {
  const client = ensureClient(config);
  return {
    resourceGroups: {
      list: client.resourceGroups.list.bind(client.resourceGroups),
      get: client.resourceGroups.get.bind(client.resourceGroups),
    },
    resources: {
      list: client.resources.list.bind(client.resources),
      getById: client.resources.getById.bind(client.resources.getById),
    },
  };
}
