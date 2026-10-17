// pipeline.test.mjs — s3_pipeline end-to-end document pipeline court.
// One discovery document flows through the full smalt substrate chain:
//   blob bytes -> Cosmos metadata -> CloudEvent -> Sentinel audit row ->
//   Confidential Ledger receipt chain -> Purview Atlas entity + lineage ->
//   Resource Graph location, plus negative surfaces.
// Surfaces are deliberately MIXED: the vendored @azure/storage-blob SDK where
// the wire supports it (container create, upload, WORM overwrite), raw REST
// everywhere else. Run via run.sh (boots + traps its own substrate).
// Failures are real; named substrate gaps are DOCUMENTED, never skipped.
import { createRequire } from "node:module";
import path from "node:path";
import crypto from "node:crypto";
import { test } from "node:test";
import assert from "node:assert/strict";

const require = createRequire(path.resolve(import.meta.dirname, "../../sdk-full/package.json"));
const { BlobServiceClient, newPipeline } = require("@azure/storage-blob");
const { CosmosClient } = require("@azure/cosmos");

const ARM = "http://127.0.0.1:9443";
const EGRESS = "http://127.0.0.1:8443";
const SUB = "00000000-0000-0000-0000-000000000000";
const RUN = crypto.randomBytes(4).toString("hex");
const ACCOUNT = "smaltacct";
const ACCOUNT_KEY = "smaltacct-key";

const T = (ms) => AbortSignal.timeout(ms);
const sha256hex = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

// Ledger hashes are hex sha256; compare case-insensitively (substrate emits
// lowercase on this OTP, the spec allows either).
const eqHex = (a, b) => a.toLowerCase() === b.toLowerCase();

// Ledger canonical form: recursively string-keyed, Jason-encodes sorted keys.
const canonicalJson = (v) => {
  if (v !== null && typeof v === "object" && !Array.isArray(v)) {
    const sorted = {};
    for (const k of Object.keys(v).sort()) sorted[k] = canonicalJson(v[k]);
    return sorted;
  }
  return v;
};

async function jfetch(url, opts = {}) {
  const token = await substrateToken();
  const headers = { authorization: `Bearer ${token}`, ...opts.headers };
  const res = await fetch(url, { ...opts, headers, signal: opts.signal ?? T(20_000) });
  const text = await res.text();
  let body = text;
  try {
    body = JSON.parse(text);
  } catch {
    /* non-JSON */
  }
  return { status: res.status, headers: res.headers, body };
}

// Substrate STS token (HS256, aud management.azure.com). The egress plane
// enforces Bearer auth (Smalt.Auth.Bearer, :enforce default); the ARM STS and
// the verifier share the dev signing secret, so a client-credentials POST to
// the exempt /oauth2/v2.0/token endpoint mints a valid token.
let TOKEN_CACHE = null;
async function substrateToken() {
  if (TOKEN_CACHE) return TOKEN_CACHE;
  const res = await fetch(`${ARM}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=00000000-0000-0000-0000-000000000000&client_secret=smalt-tf-mock-secret&scope=https%3A%2F%2Fmanagement.azure.com%2F.default",
    signal: T(20_000),
  });
  assert.equal(res.status, 200, `STS token mint 200, got ${res.status}`);
  const body = await res.json();
  assert.ok(body.access_token, "STS returned access_token");
  TOKEN_CACHE = body.access_token;
  return TOKEN_CACHE;
}

// Vendored storage SDK construction: the substrate's bearer plug accepts only
// `Authorization: Bearer`, and the SDK refuses TokenCredential over http, so
// the STS token is injected by a pipeline policy that runs last.
function makeBlobService() {
  const pipeline = newPipeline();
  pipeline.factories.push({
    name: "s3-bearer",
    sendRequest: async (req, next) => {
      req.headers.set("authorization", `Bearer ${await substrateToken()}`);
      return next(req);
    },
  });
  return new BlobServiceClient(`${EGRESS}/${ACCOUNT}`, undefined, { pipeline });
}

// ---------------------------------------------------------------------------
// Shared chain state — one discovery document, all artifacts linked to it.
// ---------------------------------------------------------------------------
const chain = { run: RUN };

// ---------------------------------------------------------------------------
// (7-prep) ARM: storage account that Resource Graph must later locate.
// ---------------------------------------------------------------------------

test("arm: create rg + storage account (LRO to Succeeded)", { timeout: 60_000 }, async () => {
  chain.rg = `e2e-pipe-rg-${RUN}`;
  chain.storageAccount = `e2epipestore${RUN}`;

  const rg = await jfetch(`${ARM}/subscriptions/${SUB}/resourcegroups/${chain.rg}?api-version=2023-07-01`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ location: "eastus" }),
  });
  assert.ok([200, 201].includes(rg.status), `rg PUT 201, got ${rg.status}: ${JSON.stringify(rg.body).slice(0, 200)}`);

  const put = await jfetch(
    `${ARM}/subscriptions/${SUB}/resourceGroups/${chain.rg}/providers/Microsoft.Storage/storageAccounts/${chain.storageAccount}?api-version=2021-04-01`,
    {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ location: "eastus", properties: { skuName: "Standard_LRS" } }),
    },
  );
  assert.equal(put.status, 202, `storage account PUT 202 (LRO), got ${put.status}: ${JSON.stringify(put.body).slice(0, 200)}`);
  const opPath = new URL(put.headers.get("azure-asyncoperation")).pathname;
  assert.ok(opPath, "Azure-AsyncOperation header present");

  let op = null;
  for (let i = 0; i < 20; i++) {
    const poll = await jfetch(`${ARM}${opPath}`);
    assert.equal(poll.status, 200, `op poll 200, got ${poll.status}`);
    op = poll.body;
    if (op.status === "Succeeded") break;
    await new Promise((r) => setTimeout(r, 500));
  }
  assert.equal(op?.status, "Succeeded", "LRO reached Succeeded");
});

// ---------------------------------------------------------------------------
// (1) Blob: multibyte discovery document into a unique immutable container.
// Vendored @azure/storage-blob SDK for create/upload; raw GET for read-back
// plus the HEAD + downloadToBuffer leg (the probe below asserts both).
// ---------------------------------------------------------------------------

test("blob: multibyte discovery upload (vendored SDK) + raw-REST byte-exact read-back", { timeout: 60_000 }, async () => {
  const service = makeBlobService();
  chain.container = `e2e-docs-${RUN}`;
  const container = service.getContainerClient(chain.container);
  await container.create({ abortSignal: T(30_000) });

  chain.docBytes = Buffer.from(
    JSON.stringify({
      document: "discovery-84",
      matter: "matter-42",
      produced: new Date().toISOString(),
      note: "multibyte 🌊 中文 évidence — run " + RUN,
    }),
    "utf8",
  );
  chain.sha256 = sha256hex(chain.docBytes);
  chain.blobName = "discovery-document.json";

  const blob = container.getBlockBlobClient(chain.blobName);
  const up = await blob.upload(chain.docBytes, chain.docBytes.length, { abortSignal: T(30_000) });
  assert.equal(up._response?.status, 201, "SDK upload 201");
  chain.blobEtag = up.etag;
  assert.ok(chain.blobEtag, "upload returned an etag");

  // Read back over raw REST (GET) and verify byte identity, plus HEAD metadata.
  const textRes = await fetch(`${EGRESS}/${ACCOUNT}/${chain.container}/${chain.blobName}`, {
    headers: { "x-ms-version": "2021-12-02", authorization: `Bearer ${await substrateToken()}` },
    signal: T(20_000),
  });
  const bytes = Buffer.from(await textRes.arrayBuffer());
  assert.ok(bytes.equals(chain.docBytes), "downloaded bytes identical (multibyte intact)");
  assert.equal(sha256hex(bytes), chain.sha256, "downloaded sha256 matches");
});

// ---------------------------------------------------------------------------
// (1-probe, flipped) HEAD blob is routed; the vendored SDK's
// downloadToBuffer (HEAD metadata + GET bytes) runs against the substrate.
// ---------------------------------------------------------------------------

test("blob: HEAD metadata + SDK downloadToBuffer byte-exact", { timeout: 30_000 }, async () => {
  const res = await jfetch(`${EGRESS}/${ACCOUNT}/${chain.container}/${chain.blobName}`, {
    method: "HEAD",
    headers: { "x-ms-version": "2021-12-02" },
  });
  assert.equal(res.status, 200, `HEAD blob 200, got ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`);
  assert.equal(res.headers.get("content-length"), String(chain.docBytes.length), "HEAD content-length equals blob size");
  assert.ok(res.headers.get("etag"), "HEAD returns etag");

  // The full SDK leg: downloadToBuffer issues HEAD then GET and reassembles.
  const service = makeBlobService();
  const blob = service.getContainerClient(chain.container).getBlockBlobClient(chain.blobName);
  const downloaded = await blob.downloadToBuffer(0, undefined, { abortSignal: T(30_000) });
  assert.ok(Buffer.from(downloaded).equals(chain.docBytes), "downloadToBuffer bytes identical (multibyte intact)");
  assert.equal(sha256hex(Buffer.from(downloaded)), chain.sha256, "downloadToBuffer sha256 matches");
});

// ---------------------------------------------------------------------------
// (2) Cosmos: register metadata doc (partitionKey matter-42).
// Raw REST with the x-ms-documentdb-partitionkey header; the vendored
// @azure/cosmos SDK bootstrap/create/read leg is exercised by the probe below.
// ---------------------------------------------------------------------------

test("cosmos: metadata doc registered with partitionkey header + linkage to blob", { timeout: 60_000 }, async () => {
  chain.dbId = `e2e-pipe-db-${RUN}`;
  chain.collId = "metadata";
  chain.docId = `disc-${RUN}`;

  const meta = {
    id: chain.docId,
    matterId: "matter-42",
    blobEtag: chain.blobEtag,
    sha256: chain.sha256,
    container: chain.container,
  };
  const create = await jfetch(`${EGRESS}/dbs/${chain.dbId}/colls/${chain.collId}/docs`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-ms-documentdb-partitionkey": '["matter-42"]',
    },
    body: JSON.stringify(meta),
  });
  assert.equal(create.status, 201, `cosmos create 201, got ${create.status}: ${JSON.stringify(create.body).slice(0, 200)}`);
  chain.cosmosEtag = create.body._etag ?? create.headers.get("etag");
  assert.ok(chain.cosmosEtag, "cosmos doc has an etag");

  const read = await jfetch(`${EGRESS}/dbs/${chain.dbId}/colls/${chain.collId}/docs/${chain.docId}`, {
    headers: { "x-ms-documentdb-partitionkey": '["matter-42"]' },
  });
  assert.equal(read.status, 200, `cosmos read 200, got ${read.status}`);
  assert.equal(read.body.blobEtag, chain.blobEtag, "metadata doc cites blob etag");
  assert.equal(read.body.sha256, chain.sha256, "metadata doc cites content sha256");
  assert.equal(read.body.matterId, "matter-42", "partition key value stored");
});

test("cosmos: @azure/cosmos SDK bootstrap + create + read through the REAL SDK", { timeout: 60_000 }, async () => {
  const cosmos = new CosmosClient({
    endpoint: EGRESS,
    key: crypto.randomBytes(32).toString("hex"),
    retryOptions: { maxRetryAttemptCount: 0 },
    connectionPolicy: { enableEndpointsDiscovery: false },
  });

  // Bootstrap: ClientContext.create → GET / (account root) must return the
  // minimal DatabaseAccount JSON.
  const { database } = await cosmos.databases.createIfNotExists({ id: `probe-db-${RUN}` }, { abortSignal: T(30_000) });
  assert.equal(database.id, `probe-db-${RUN}`, "SDK database create resolved");

  const { container } = await database.containers.createIfNotExists(
    { id: `probe-coll-${RUN}`, partitionKey: { paths: ["/matterId"] } },
    { abortSignal: T(30_000) },
  );
  const sdkDoc = {
    id: `sdk-doc-${RUN}`,
    matterId: "matter-42",
    blobEtag: chain.blobEtag,
    sha256: chain.sha256,
  };
  const created = await container.items.create(sdkDoc, { abortSignal: T(30_000) });
  assert.equal(created.statusCode, 201, `SDK item create 201, got ${created.statusCode}`);
  assert.ok(created.resource._etag, "SDK item has _etag");

  const read = await container.item(sdkDoc.id, "matter-42").read({ abortSignal: T(30_000) });
  assert.equal(read.statusCode, 200, `SDK item read 200, got ${read.statusCode}`);
  assert.equal(read.resource.blobEtag, chain.blobEtag, "SDK read-back cites blob etag");
  assert.equal(read.resource.sha256, chain.sha256, "SDK read-back cites sha256");
});

// ---------------------------------------------------------------------------
// (2-negative) Stale If-Match replace -> 412.
// ---------------------------------------------------------------------------

test("cosmos negative: stale If-Match replace -> 412", { timeout: 30_000 }, async () => {
  const res = await jfetch(`${EGRESS}/dbs/${chain.dbId}/colls/${chain.collId}/docs/${chain.docId}`, {
    method: "PUT",
    headers: {
      "content-type": "application/json",
      "x-ms-documentdb-partitionkey": '["matter-42"]',
      // Definitively stale (wrong) etag: an honest concurrent writer won.
      "if-match": '"00000000-0000-0000-0000-000000000000"',
    },
    body: JSON.stringify({ id: chain.docId, matterId: "matter-42", blobEtag: "stale" }),
  });
  assert.equal(res.status, 412, `stale If-Match -> 412, got ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`);
});

// ---------------------------------------------------------------------------
// (3) CloudEvent document.discovered (structured single-object POST).
// ---------------------------------------------------------------------------

test("cloudevent: publish document.discovered -> stored with returned id", { timeout: 30_000 }, async () => {
  chain.topic = `docpipe-${RUN}`;
  chain.ceId = chain.docId;

  const pub = await jfetch(`${EGRESS}/topics/${chain.topic}/events`, {
    method: "POST",
    headers: { "content-type": "application/cloudevents+json" },
    body: JSON.stringify({
      specversion: "1.0",
      type: "document.discovered",
      source: "/smalt/e2e/s3-pipeline",
      id: chain.ceId,
      data: { docId: chain.docId, blobEtag: chain.blobEtag, sha256: chain.sha256 },
    }),
  });
  assert.equal(pub.status, 200, `publish 200, got ${pub.status}: ${JSON.stringify(pub.body).slice(0, 200)}`);
  assert.equal(pub.body.status, "Published");
  assert.equal(pub.body.id, chain.ceId, "returned id equals the event id");

  const list = await jfetch(`${EGRESS}/topics/${chain.topic}/events`);
  assert.equal(list.status, 200);
  const stored = list.body.find((e) => e.id === chain.ceId);
  assert.ok(stored, "event stored under its returned id");
  assert.equal(stored.type, "document.discovered");
  assert.equal(stored.data.blobEtag, chain.blobEtag, "event data cites blob etag");
  assert.equal(stored.data.sha256, chain.sha256, "event data cites content sha256");
});

// ---------------------------------------------------------------------------
// (3-negative) CloudEvent missing type -> 400, all-or-nothing.
// ---------------------------------------------------------------------------

test("cloudevent negative: missing type -> 400 and nothing stored (all-or-nothing)", { timeout: 30_000 }, async () => {
  const before = await jfetch(`${EGRESS}/topics/${chain.topic}/events`);
  const countBefore = before.body.length;

  const noType = await jfetch(`${EGRESS}/topics/${chain.topic}/events`, {
    method: "POST",
    headers: { "content-type": "application/cloudevents+json" },
    body: JSON.stringify({
      specversion: "1.0",
      source: "/smalt/e2e/s3-pipeline",
      id: `neg-notype-${RUN}`,
    }),
  });
  assert.equal(noType.status, 400, `missing type -> 400, got ${noType.status}`);

  // All-or-nothing: a batch carrying one valid + one invalid event must 400
  // and store NEITHER.
  const batch = await jfetch(`${EGRESS}/topics/${chain.topic}/events`, {
    method: "POST",
    headers: { "content-type": "application/cloudevents-batch+json" },
    body: JSON.stringify([
      { specversion: "1.0", type: "document.audit", source: "/smalt/e2e", id: `neg-valid-${RUN}`, data: {} },
      { specversion: "1.0", source: "/smalt/e2e", id: `neg-invalid-${RUN}` },
    ]),
  });
  assert.equal(batch.status, 400, `mixed batch -> 400, got ${batch.status}`);

  const listAfter = await jfetch(`${EGRESS}/topics/${chain.topic}/events`);
  assert.equal(listAfter.body.length, countBefore, "no events added by rejected posts");
  assert.ok(!listAfter.body.some((e) => String(e.id).startsWith(`neg-`)), "neither batch member stored");
});

// ---------------------------------------------------------------------------
// (4) Sentinel: audit row citing the CloudEvent id, then KQL query it back.
// ---------------------------------------------------------------------------

test("sentinel: audit row ingest + KQL query cites the CloudEvent id", { timeout: 60_000 }, async () => {
  chain.dcr = `docpipe-dcr-${RUN}`;
  const row = {
    TimeGenerated: new Date().toISOString(),
    docId: chain.docId,
    eventId: chain.ceId,
    blobEtag: chain.blobEtag,
  };
  const ingest = await jfetch(
    `${EGRESS}/dataCollectionRules/${chain.dcr}/streams/Custom-DocumentAudit?api-version=2023-01-01`,
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify([row]) },
  );
  assert.equal(ingest.status, 200, `ingest 200, got ${ingest.status}: ${JSON.stringify(ingest.body).slice(0, 200)}`);
  assert.equal(ingest.body.ingestionStatus, "Accepted");

  const q = await jfetch(`${EGRESS}/v1/workspaces/${chain.dcr}/query`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: `| where eventId == '${chain.ceId}'` }),
  });
  assert.equal(q.status, 200, `query 200, got ${q.status}: ${JSON.stringify(q.body).slice(0, 200)}`);
  const table = q.body.tables[0];
  const rows = table.rows.map((r) => Object.fromEntries(table.columns.map((c, i) => [c.name, r[i]])));
  const hit = rows.find((r) => r.eventId === chain.ceId);
  assert.ok(hit, "query returns the audit row citing the CloudEvent id");

  // The five augmented string columns are present and string-typed.
  for (const name of ["ledgerId", "tenantId", "subjectSha256", "eventId", "sha256Hash"]) {
    assert.ok(table.columns.some((c) => c.name === name), `column ${name} present`);
    assert.equal(typeof hit[name], "string", `column ${name} is a string`);
  }
  assert.equal(hit.docId, chain.docId, "audit row cites the doc id");
});

// ---------------------------------------------------------------------------
// (5) Confidential Ledger: append + receipt chain across TWO appends.
// ---------------------------------------------------------------------------

test("ledger: two appends -> receipts chain by prev_hash/merkle_root", { timeout: 60_000 }, async () => {
  const append = async (contents) =>
    jfetch(`${EGRESS}/app/transactions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(contents),
    });

  const c1 = { docHash: chain.sha256, blobEtag: chain.blobEtag, docId: chain.docId };
  const r1 = await append(c1);
  assert.equal(r1.status, 201, `append1 201, got ${r1.status}: ${JSON.stringify(r1.body).slice(0, 200)}`);
  const rec1 = r1.body;
  assert.equal(rec1.prev_hash, "0".repeat(64), "genesis prev_hash is 64 zeros");
  assert.equal(rec1.contents.docHash, chain.sha256, "receipt contents cite doc hash");

  // Recompute the substrate's data_hash: sha256(canonical sorted-key JSON).
  const dataHash = sha256hex(Buffer.from(JSON.stringify(canonicalJson(c1)), "utf8"));
  assert.ok(eqHex(rec1.data_hash, dataHash), `data_hash = sha256(canonical contents) (${rec1.data_hash} vs ${dataHash})`);

  const c2 = { docHash: chain.sha256, blobEtag: chain.blobEtag, docId: chain.docId, audit: "chain-check-2" };
  const r2 = await append(c2);
  assert.equal(r2.status, 201, `append2 201, got ${r2.status}`);
  const rec2 = r2.body;

  // Chain order across TWO appends: rec2.prev_hash == rec1.merkle_root.
  assert.equal(rec2.prev_hash, rec1.merkle_root, "second receipt chains to first merkle root");
  const m1 = sha256hex(Buffer.from(rec1.prev_hash + rec1.data_hash, "utf8"));
  const m2 = sha256hex(Buffer.from(rec2.prev_hash + rec2.data_hash, "utf8"));
  assert.ok(eqHex(rec1.merkle_root, m1), "receipt1 merkle_root recomputes");
  assert.ok(eqHex(rec2.merkle_root, m2), "receipt2 merkle_root recomputes");
  assert.notEqual(rec2.transactionId, rec1.transactionId, "monotonic tx ids");

  const latest = await jfetch(`${EGRESS}/app/transactions/latest`);
  assert.equal(latest.status, 200);
  assert.equal(latest.body.transactionId, rec2.transactionId, "GET latest is the second append");
  assert.equal(latest.body.prev_hash, rec1.merkle_root, "latest receipt preserves chain order");

  const byId = await jfetch(`${EGRESS}/app/transactions/${rec1.transactionId}`);
  assert.equal(byId.status, 200);
  assert.equal(byId.body.merkle_root, rec1.merkle_root, "tx1 receipt stable by id");
});

// ---------------------------------------------------------------------------
// (6) Purview Atlas: entity + bulk second entity, lineage depth 2 both ways.
// ---------------------------------------------------------------------------

test("purview: doc entity + bulk process entity + lineage depth 2", { timeout: 60_000 }, async () => {
  const entity = await jfetch(`${EGRESS}/atlas/v2/entity`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      typeName: "smalt_document",
      attributes: {
        name: chain.docId,
        qualifiedName: `smalt://blob/${chain.container}/${chain.blobName}`,
        docId: chain.docId,
        sha256: chain.sha256,
      },
    }),
  });
  assert.equal(entity.status, 201, `entity create 201, got ${entity.status}: ${JSON.stringify(entity.body).slice(0, 200)}`);
  chain.docGuid = entity.body.guid;
  assert.ok(chain.docGuid, "guid assigned");

  const bulk = await jfetch(`${EGRESS}/atlas/v2/entity/bulk`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      entities: [
        {
          typeName: "smalt_discovery_process",
          attributes: {
            name: `discovery-run-${RUN}`,
            qualifiedName: `smalt://process/discovery-${RUN}`,
            docId: chain.docId,
          },
        },
      ],
    }),
  });
  assert.equal(bulk.status, 201, `bulk create 201, got ${bulk.status}`);
  const procGuid = Object.keys(bulk.body.guidAssignments)[0];
  assert.ok(procGuid, "bulk assigned a guid");

  const got = await jfetch(`${EGRESS}/atlas/v2/entity/guid/${chain.docGuid}`);
  assert.equal(got.status, 200);
  assert.equal(got.body.attributes?.docId, chain.docId, "entity cites docId");

  // Lineage both directions, depth 2.
  const lineage = await jfetch(`${EGRESS}/atlas/v2/lineage/both/${chain.docGuid}?depth=2`);
  assert.equal(lineage.status, 200, `lineage 200, got ${lineage.status}`);
  assert.equal(lineage.body.baseEntityGuid, chain.docGuid);
  assert.ok(chain.docGuid in lineage.body.guidEntityMap, "base entity in guidEntityMap");

  // Relations: mint a real lineage edge over the wire (POST
  // /atlas/v2/relationship → Purview.put_edge, stored in :smalt_purview_edges
  // which the lineage BFS walks) and assert the lineage reports it.
  const rel = await jfetch(`${EGRESS}/atlas/v2/relationship`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      relationship: {
        typeName: "smalt_process_input",
        end1: { guid: procGuid },
        end2: { guid: chain.docGuid },
      },
    }),
  });
  assert.equal(rel.status, 201, `relationship 201, got ${rel.status}: ${JSON.stringify(rel.body).slice(0, 200)}`);
  assert.ok(rel.body.guid, "relationship returned a guid");

  const lineageAfter = await jfetch(`${EGRESS}/atlas/v2/lineage/both/${chain.docGuid}?depth=2`);
  assert.equal(lineageAfter.status, 200, `lineage-after 200, got ${lineageAfter.status}`);
  assert.ok(
    lineageAfter.body.relations.some(
      (r) => r.fromEntityId === procGuid && r.toEntityId === chain.docGuid,
    ),
    "lineage relations include the minted edge",
  );
  assert.ok(procGuid in lineageAfter.body.guidEntityMap, "process entity reachable via lineage");
});

// ---------------------------------------------------------------------------
// (7) Resource Graph: the query finds the storage account holding the blob.
// ---------------------------------------------------------------------------

test("resourcegraph: where name == finds the storage account", { timeout: 30_000 }, async () => {
  const res = await jfetch(`${EGRESS}/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      query: `where name == '${chain.storageAccount}'`,
    }),
  });
  assert.equal(res.status, 200, `resource graph 200, got ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`);
  assert.equal(res.body.totalRecords, 1, "exactly one resource matches");
  const hit = res.body.data[0];
  assert.equal(hit.name, chain.storageAccount);
  assert.equal(hit.type, "Microsoft.Storage/storageAccounts");
  assert.ok(hit.id.includes(chain.rg), "resource id names the rg");
  assert.ok(hit.id.toLowerCase().includes(chain.storageAccount), "resource id holds the account");
});

// ---------------------------------------------------------------------------
// (8-negative) Blob overwrite in immutable container -> 409 (vendored SDK).
// ---------------------------------------------------------------------------

test("blob negative: overwrite in immutable container -> 409", { timeout: 30_000 }, async () => {
  const service = makeBlobService();
  const blob = service.getContainerClient(chain.container).getBlockBlobClient(chain.blobName);
  await assert.rejects(
    () => blob.upload(Buffer.from("tamper"), 6, { abortSignal: T(30_000) }),
    (err) => {
      assert.equal(err.statusCode, 409, `immutable overwrite -> 409, got ${err.statusCode}`);
      return true;
    },
  );

  // The original bytes survive the refused overwrite (raw GET).
  const textRes = await fetch(`${EGRESS}/${ACCOUNT}/${chain.container}/${chain.blobName}`, {
    headers: { "x-ms-version": "2021-12-02", authorization: `Bearer ${await substrateToken()}` },
    signal: T(20_000),
  });
  const bytes = Buffer.from(await textRes.arrayBuffer());
  assert.ok(bytes.equals(chain.docBytes), "original bytes unchanged after 409");
});

// ---------------------------------------------------------------------------
// Full-chain linkage: every artifact references the prior artifact's id/hash.
// ---------------------------------------------------------------------------

test("chain linkage: blob -> cosmos -> cloudevent -> sentinel -> ledger -> purview", { timeout: 30_000 }, async () => {
  assert.ok(chain.blobEtag, "blob artifact exists");
  assert.equal(chain.sha256, sha256hex(chain.docBytes), "sha256 of the uploaded bytes");

  // CloudEvent cites the cosmos doc id + blob etag/hash.
  const list = await jfetch(`${EGRESS}/topics/${chain.topic}/events`);
  const evt = list.body.find((e) => e.id === chain.ceId);
  assert.ok(evt, "cloudevent stored");
  assert.equal(evt.data.docId, chain.docId, "event -> cosmos doc id");
  assert.equal(evt.data.blobEtag, chain.blobEtag, "event -> blob etag");

  // Sentinel row cites the CloudEvent id.
  const q = await jfetch(`${EGRESS}/v1/workspaces/${chain.dcr}/query`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: `| where eventId == '${chain.ceId}'` }),
  });
  const t = q.body.tables[0];
  const rows = t.rows.map((r) => Object.fromEntries(t.columns.map((c, i) => [c.name, r[i]])));
  assert.equal(rows.length, 1, "exactly one audit row for the event");
  assert.equal(rows[0].docId, chain.docId, "sentinel -> doc id");

  // Ledger cites the doc hash + blob etag.
  const tx = await jfetch(`${EGRESS}/app/transactions/1.1`);
  assert.ok(eqHex(tx.body.contents.docHash, chain.sha256), "ledger -> content sha256");
  assert.equal(tx.body.contents.blobEtag, chain.blobEtag, "ledger -> blob etag");

  // Purview entity cites the doc id + hash.
  const ent = await jfetch(`${EGRESS}/atlas/v2/entity/guid/${chain.docGuid}`);
  assert.equal(ent.body.attributes.docId, chain.docId, "purview -> doc id");
  assert.equal(ent.body.attributes.sha256, chain.sha256, "purview -> content sha256");
});
