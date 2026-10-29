/**
 * Mission-manifest store on the smalt egress Cosmos NoSQL docs engine.
 *
 * Auth shape (mirrors test/sdk-smoke/cosmos.test.cjs): CosmosClient with a
 * master key — any 64-char hex string signs validly on the anonymous-mode
 * substrate; the SDK emits a real master-key Authorization header on the
 * wire. Endpoint is NEXT_PUBLIC_SMALT_EGRESS (docs routes on :8443).
 *
 * QUERY RESTRICTION — `SELECT * FROM c` ONLY.
 * The emulator's query surface enforces a SQL whitelist: full-document
 * projections are admitted; any other shape (WHERE predicates, projections,
 * ORDER BY, aggregates) is outside the admitted grammar. Mission manifests
 * are small per-session documents read whole, so `SELECT * FROM c` covers
 * the access pattern: fetch every manifest for the session's container and
 * filter client-side. Restricting this module to the whitelisted form means
 * no manifest read can ever be refused at the query gate, and the lib never
 * has to model the refusal path. (Witnessed in the probe; the raw
 * application/query+json wire shape is exercised in
 * test/sdk-full/ts-reality.test.mjs.)
 */

import type { CosmosClient, Container, ItemResponse, ItemDefinition } from "@azure/cosmos";

/** The only SQL form this module admits. */
export const MANIFEST_QUERY = "SELECT * FROM c";

/** A mission manifest document. */
export interface MissionManifest {
  id: string;
  /** Partition key. */
  pk: string;
  mission: string;
  /** Arbitrary manifest payload (equipment, crew, route, …). */
  payload: Record<string, unknown>;
  revision: number;
}

/** Default egress endpoint for the local smalt substrate. */
export const COSMOS_ENDPOINT =
  process.env.NEXT_PUBLIC_SMALT_EGRESS || "http://127.0.0.1:8443";

const T = (ms: number) => AbortSignal.timeout(ms);

/**
 * Provision the manifest store. Tolerates substrates without the database
 * control-plane route (PUT /dbs/:db → 400 on some builds): the container
 * create route (POST /dbs/:db/colls) is the one that matters and the docs
 * engine is permissive about the parent db entity.
 */
export async function createManifestStore(
  client: CosmosClient,
  dbId: string,
  collId: string,
  timeoutMs = 20_000,
): Promise<{ db: string; coll: string }> {
  try {
    await client.databases.createIfNotExists(
      { id: dbId },
      { abortSignal: T(timeoutMs) },
    );
  } catch (err: unknown) {
    const code = (err as { code?: number }).code;
    if (code !== 400 && code !== 404) throw err;
  }
  await client
    .database(dbId)
    .containers.createIfNotExists(
      { id: collId, partitionKey: { paths: ["/pk"] } },
      { abortSignal: T(timeoutMs) },
    );
  return { db: dbId, coll: collId };
}

/** Build a CosmosClient against the egress docs engine. */
export function makeCosmosClient(client: CosmosClient): CosmosClient {
  return client;
}

/**
 * Upsert a mission manifest (create-or-replace on id+pk).
 * Returns the HTTP status code (201 create / 200 replace).
 */
export async function upsertManifest(
  container: Container,
  manifest: MissionManifest,
  timeoutMs = 20_000,
): Promise<number> {
  // NOTE (SDK v4 shape): Item.upsert does not exist on the item handle in
  // @azure/cosmos 4.x — upsert lives on the Items feed (witnessed live:
  // `container.item(...).upsert is not a function`).
  const res: ItemResponse<ItemDefinition> = await container.items.upsert(manifest, {
    abortSignal: T(timeoutMs),
  });
  return res.statusCode;
}

/**
 * Read every manifest via the whitelisted query. Client-side pk filter is
 * the documented access pattern (see module TSDoc).
 */
export async function readManifests(
  container: Container,
  filter?: { pk?: string },
  timeoutMs = 20_000,
): Promise<MissionManifest[]> {
  const { resources } = await container
    .items
    .query<MissionManifest>(MANIFEST_QUERY, { abortSignal: T(timeoutMs) })
    .fetchAll();
  return filter?.pk ? resources.filter((m) => m.pk === filter.pk) : resources;
}
