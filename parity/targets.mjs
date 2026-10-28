// targets.mjs — target registry for the parity harness.
// Each target: reachability probe, SDK client factories, and per-suite
// adapters whose ONLY asymmetry is prepare()/cleanup() (see parity/README.md
// normalization law). Official SDKs only; no emulator-internal imports.
import { StorageSharedKeyCredential, BlobServiceClient } from "@azure/storage-blob";
import { QueueServiceClient } from "@azure/storage-queue";
import { CosmosClient } from "@azure/cosmos";
import { Agent } from "node:https";

// Azurite well-known dev account (same key the storage SDKs hard-code for
// UseDevelopmentConnectionString).
export const AZURITE_ACCOUNT = "devstoreaccount1";
export const AZURITE_KEY =
  "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";

// Cosmos DB Emulator well-known master key (documented, fixed).
export const EMULATOR_KEY =
  "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==";

const env = (name, dflt) => (process.env[name] && process.env[name] !== "" ? process.env[name] : dflt);

export const SMALT = {
  id: "smalt",
  label: "smalt substrate",
  armBase: env("SMALT_PARITY_ARM", "http://127.0.0.1:9443"),
  egressBase: env("SMALT_PARITY_EGRESS", "http://127.0.0.1:8443"),
  blobAccount: env("SMALT_PARITY_BLOB_ACCOUNT", "smaltacct"),
  blobKey: env("SMALT_PARITY_BLOB_KEY", "smaltacct-key"),
  cosmosKey: env("SMALT_PARITY_COSMOS_KEY", "parity-dev-key"),
  // Ownership gate, same shape as the verification suite's: anonymous ARM
  // must answer 200 on /metadata/endpoints or there is no smalt to compare.
  async probe() {
    const res = await fetch(`${this.armBase}/metadata/endpoints`, {
      signal: AbortSignal.timeout(5_000),
    }).catch(() => null);
    return res && res.ok;
  },
  blob() {
    const cred = new StorageSharedKeyCredential(this.blobAccount, this.blobKey);
    return new BlobServiceClient(`${this.egressBase}/${this.blobAccount}`, cred, {
      retryOptions: { maxRetries: 0 },
    });
  },
  queue() {
    const cred = new StorageSharedKeyCredential(this.blobAccount, this.blobKey);
    return new QueueServiceClient(`${this.egressBase}/${this.blobAccount}`, cred, {
      retryOptions: { maxRetries: 0 },
    });
  },
  tableCoords() {
    return { baseUrl: `${this.egressBase}/${this.blobAccount}`, account: this.blobAccount, key: this.blobKey };
  },
  async cosmosAdapter(dbId, collId) {
    const client = new CosmosClient({
      endpoint: this.egressBase,
      key: this.cosmosKey,
      connectionPolicy: {
        enableEndpointDiscovery: false,
        retryOptions: { maxRetries: 0 },
      },
    });
    const container = client.database(dbId).container(collId);
    // Known-good smalt workaround (lifted from verification/ts/wf2/index.ts:32):
    // the substrate's colls GET answers 404, so seed the SDK's pk-definition
    // cache with the /id definition the docs engine itself enforces.
    client.clientContext.partitionKeyDefinitionCache[container.url] = {
      path: "/id",
      paths: ["/id"],
      kind: "Hash",
      version: 1,
    };
    return { client, container };
  },
};

export const AZURITE = {
  id: "azurite",
  label: "Azurite blob/queue/table",
  blobBase: env("PARITY_AZURITE_BLOB", "http://127.0.0.1:10000"),
  queueBase: env("PARITY_AZURITE_QUEUE", "http://127.0.0.1:10001"),
  tableBase: env("PARITY_AZURITE_TABLE", "http://127.0.0.1:10002"),
  async probe() {
    // Any HTTP answer (even 400 on /) means the listener is up.
    const res = await fetch(`${this.blobBase}/`, {
      signal: AbortSignal.timeout(5_000),
    }).catch(() => null);
    return res !== null;
  },
  blob() {
    const cred = new StorageSharedKeyCredential(AZURITE_ACCOUNT, AZURITE_KEY);
    return new BlobServiceClient(`${this.blobBase}/${AZURITE_ACCOUNT}`, cred, {
      retryOptions: { maxRetries: 0 },
    });
  },
  queue() {
    const cred = new StorageSharedKeyCredential(AZURITE_ACCOUNT, AZURITE_KEY);
    return new QueueServiceClient(`${this.queueBase}/${AZURITE_ACCOUNT}`, cred, {
      retryOptions: { maxRetries: 0 },
    });
  },
  tableCoords() {
    return { baseUrl: `${this.tableBase}/${AZURITE_ACCOUNT}`, account: AZURITE_ACCOUNT, key: AZURITE_KEY };
  },
};

export const COSMOS_EMULATOR = {
  id: "emulator",
  label: "Azure Cosmos DB Emulator",
  endpoint: env("PARITY_COSMOS_ENDPOINT", "https://127.0.0.1:8081"),
  async probe() {
    const res = await fetch(this.endpoint, {
      signal: AbortSignal.timeout(5_000),
      // Self-signed emulator cert; probe only.
    }).catch((e) => (/certificate|SELF_SIGNED|DEPTH_ZERO/i.test(String(e?.cause?.code ?? e?.message)) ? true : null));
    // Node rejects the self-signed cert at fetch level — that still proves
    // the listener answered TLS. A real TCP refusal returns null.
    return res === true || (res && res.status > 0);
  },
  async cosmosAdapter(dbId, collId) {
    const client = new CosmosClient({
      endpoint: this.endpoint,
      key: EMULATOR_KEY,
      // Self-signed emulator certificate.
      agent: new Agent({ rejectUnauthorized: false }),
      connectionPolicy: {
        enableEndpointDiscovery: false,
        retryOptions: { maxRetries: 0 },
      },
    });
    const container = client.database(dbId).container(collId);
    // Reference-side prepare (adapter asymmetry lives here and nowhere
    // else): real control-plane creation, where the substrate auto-ensures
    // on first docs write instead.
    await client.databases.createIfNotExists({ id: dbId });
    await client.database(dbId).containers.createIfNotExists({
      id: collId,
      partitionKey: { paths: ["/id"], kind: "Hash" },
    });
    // Warm-up write: the emulator's first write on a fresh container pays
    // the backend partition-open cost (observed >30s) and occasionally 500s
    // (known emulator flakiness) — pay it here, unscored, with bounded
    // retries; a warm-up that still fails makes the leg skip loudly.
    let warmOk = false;
    for (let i = 0; i < 5 && !warmOk; i++) {
      try {
        await container.items.upsert({ id: "warmup", v: -1 });
        warmOk = true;
      } catch {
        // SLEEP-CLASS: POLL-STEP — bounded retry backoff on the warm-up
        // observable; owns no test coordination.
        await new Promise((r) => setTimeout(r, 2_000));
      }
    }
    if (!warmOk) throw new Error("emulator warm-up write failed after 5 attempts (500s)");
    await container.item("warmup", "warmup").delete().catch(() => {});
    return { client, container };
  },
};
