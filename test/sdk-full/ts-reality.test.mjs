// ts-reality.test.mjs — reality-grade TypeScript court.
// Real @azure SDKs (real npm installs) against the live smalt substrate:
// real OAuth over TLS to the substrate STS twin, real BYOK/SKR flow, real
// Cosmos docs engine, Blob (+WORM), Service Bus sessions, Event Hubs.
// Zero skips. AbortSignal timeouts everywhere. Where a real SDK cannot be
// pointed at the substrate, the probe is a DOCUMENTED FAIL (named limitation),
// never a skip and never a fake pass. Run via ts-run.mjs.
import { createRequire } from "node:module";
import path from "node:path";
import crypto from "node:crypto";
import { test } from "node:test";
import assert from "node:assert/strict";

const require = createRequire(path.join(import.meta.dirname, "package.json"));
const {
  ClientSecretCredential,
} = require("@azure/identity");
const { CosmosClient } = require("@azure/cosmos");
const {
  BlobServiceClient,
  StorageSharedKeyCredential,
} = require("@azure/storage-blob");
const { ServiceBusClient, ServiceBusAdministrationClient } = require("@azure/service-bus");
const {
  EventHubProducerClient,
  EventHubConsumerClient,
} = require("@azure/event-hubs");
const { KeyClient } = require("@azure/keyvault-keys");

try { require("@azure/logger").AzureLogger.silent = true; } catch {}

// --- substrate coordinates (wired by ts-run.mjs) -----------------------------
const PORTS = {
  amqp: Number(process.env.SMALT_TS_AMQP_PORT || 5672),
  eh: Number(process.env.SMALT_TS_EH_PORT || 5673),
  arm: Number(process.env.SMALT_TS_ARM_PORT || 9443),
  egress: Number(process.env.SMALT_TS_EGRESS_PORT || 8443),
  armTls: Number(process.env.SMALT_TS_ARM_TLS_PORT || 9444),
};
const ARM = `http://127.0.0.1:${PORTS.arm}`;
const ARM_TLS = `https://localhost:${PORTS.armTls}`;
const EGRESS = `http://127.0.0.1:${PORTS.egress}`;
const MEASUREMENT = process.env.SMALT_TS_MEASUREMENT || "11".repeat(32);
const SB_KEY = process.env.SMALT_TS_SB_SHARED_KEY;
if (!SB_KEY) {
  console.error("[ts-reality] SMALT_TS_SB_SHARED_KEY missing — run via ts-run.mjs");
  process.exit(1);
}

// smalt-tf mock AAD identity (all-zero GUIDs per scripts/smalt-tf).
const TENANT = "00000000-0000-0000-0000-000000000000";
const CLIENT = "00000000-0000-0000-0000-000000000000";
const SECRET = "smalt-tf-mock-secret";
const SUB = "00000000-0000-0000-0000-000000000000";

const T = (ms) => AbortSignal.timeout(ms);

function base64urlDecode(seg) {
  return JSON.parse(Buffer.from(seg, "base64url").toString("utf8"));
}

function assertJwt(token) {
  const segs = token.split(".");
  assert.equal(segs.length, 3, "token is 3 base64url segments");
  return base64urlDecode(segs[1]);
}

// Close an SDK handle without letting a wedged close hang the suite.
async function boundedClose(handle, ms = 5000) {
  try {
    await Promise.race([
      Promise.resolve(handle.close()).catch(() => {}),
      new Promise((resolve) => setTimeout(resolve, ms)),
    ]);
  } catch { /* leave it to teardown */ }
}

// ---------------------------------------------------------------------------
// Minimal manual SharedKey signer for raw blob REST bindings the JS SDK does
// not expose (legal hold). StringToSign per Azure Storage SharedKey spec.
// ---------------------------------------------------------------------------
async function sharedKeyFetch(url, method, account, keyB64, extraHeaders = {}, body = undefined) {
  const u = new URL(url);
  const xms = Object.entries({ ...extraHeaders })
    .filter(([k]) => k.toLowerCase().startsWith("x-ms-"))
    .sort(([a], [b]) => (a < b ? -1 : 1));
  const canonicalHeaders = xms.map(([k, v]) => `${k.toLowerCase()}:${v}\n`).join("");
  const canonicalResource =
    `/${account}${u.pathname}` +
    [...u.searchParams.entries()]
      .map(([k, v]) => `\n${k.toLowerCase()}:${v}`)
      .join("");
  const contentLength = body ? Buffer.byteLength(body) : "";
  const stringToSign = [
    method,
    "", // Content-Encoding
    "", // Content-Language
    contentLength,
    "", // Content-MD5
    "", // Content-Type
    "", // Date
    "", // If-Modified-Since
    "", // If-Match
    "", // If-None-Match
    "", // If-Unmodified-Since
    "", // Range
    canonicalHeaders + canonicalResource,
  ].join("\n");
  const sig = crypto
    .createHmac("sha256", Buffer.from(keyB64, "base64"))
    .update(stringToSign, "utf8")
  .digest("base64");
  const headers = {
    ...extraHeaders,
    "x-ms-date": new Date().toUTCString(),
    "x-ms-version": "2021-12-02",
    Authorization: `SharedKey ${account}:${sig}`,
  };
  return fetch(url, { method, headers, body });
}

// ---------------------------------------------------------------------------
// 1. OAuth reality
// ---------------------------------------------------------------------------

test("oauth: real client_credentials token over TLS from the substrate STS twin", { timeout: 30_000 }, async () => {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: CLIENT,
    client_secret: SECRET,
    scope: "https://management.azure.com/.default",
  });
  const res = await fetch(`${ARM_TLS}/${TENANT}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
    signal: T(20_000),
  });
  assert.equal(res.status, 200, `token endpoint over TLS status ${res.status}`);
  const payload = assertJwt((await res.json()).access_token);
  assert.equal(payload.tid, TENANT, "JWT tid equals the mock tenant GUID");
  assert.equal(payload.aud, "https://management.azure.com", "JWT aud is the ARM audience");
  assert.ok(payload.exp > Date.now() / 1000, "token not expired");
  assert.ok(payload.roles.includes("Contributor"), "substrate issues Contributor role claim");
});

test("oauth control: dead authority → real transport failure, proving token acquisition targets the substrate (no real-Azure fallback)", { timeout: 30_000 }, async () => {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: CLIENT,
    client_secret: "whatever",
    scope: "https://management.azure.com/.default",
  });
  await assert.rejects(
    () => fetch("https://localhost:9445/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
      signal: T(20_000),
    }),
    (err) => {
      assert.ok(err instanceof Error, "failure is a real Error");
      assert.match(
        String(err.cause?.code || err.message),
        /ECONNREFUSED|ECONNRESET|fetch failed/i,
        `error is a real transport failure against the dead authority: ${err.message}`,
      );
      return true;
    },
  );
});

test("oauth azidentity: ClientSecretCredential end-to-end — DOCUMENTED FAIL while the discovery envelope routes off-substrate", { timeout: 60_000 }, async () => {
  const cred = new ClientSecretCredential(TENANT, CLIENT, SECRET, { authorityHost: ARM_TLS });
  const { outcome, detail } = await (async () => {
    try {
      const t = await cred.getToken("https://management.azure.com/.default", { abortSignal: T(45_000) });
      return { outcome: "resolved", detail: `token acquired (first 16 chars: ${t.token.slice(0, 16)}…)` };
    } catch (err) {
      return { outcome: "rejected", detail: `${err.name}: ${err.message}` };
    }
  })();
  console.log(`[ts-reality] azidentity ClientSecretCredential.getToken → ${outcome}: ${detail}`);
  if (outcome === "rejected") {
    assert.fail(
      `DOCUMENTED FAIL — azidentity ClientSecretCredential cannot acquire a token from the substrate: ${detail}. ` +
      `Limitation: the substrate tenant-discovery envelope (GET /{tid}/v2.0/.well-known/openid-configuration) ` +
      `publishes token_endpoint/issuer on https://login.smalt.local:443 (NXDOMAIN), and msal-node follows the ` +
      `envelope literally, so the client_credentials POST never lands on the substrate STS. ` +
      `The raw TLS client_credentials POST above proves the STS contract itself.`,
    );
  }
});

// ---------------------------------------------------------------------------
// 2. Key Vault SDK reality + BYOK / SKR flow
// ---------------------------------------------------------------------------

test("kv sdk: KeyClient.createKey over https TLS twin — DOCUMENTED FAIL (route placement)", { timeout: 60_000 }, async () => {
  const cred = new ClientSecretCredential(TENANT, CLIENT, SECRET, { authorityHost: ARM_TLS });
  const { outcome, detail } = await (async () => {
    try {
      const kc = new KeyClient(ARM_TLS, cred);
      const key = await kc.createKey("ts-court-byok", "RSA", { abortSignal: T(45_000) });
      return { outcome: "resolved", detail: `kid=${key.id}` };
    } catch (err) {
      return { outcome: "rejected", detail: `${err.name}: ${err.message} (statusCode=${err.statusCode ?? "n/a"})` };
    }
  })();
  if (outcome === "rejected") {
    assert.fail(
      `DOCUMENTED FAIL — KeyClient.createKey (PUT/POST /keys/{name}/create) over https to the TLS twin ` +
      `got ${detail}. Limitation: the Key Vault data plane (POST /keys/:name/create, /keys/:name/release, ` +
      `crypto actions) is mounted on the http egress listener :${PORTS.egress} only; the TLS :${PORTS.armTls} ` +
      `twin serves the ARM router, which has no /keys routes. The BYOK flow is exercised raw-REST below.`,
    );
  }
});

test("kv sdk: KeyClient.getKey against the http egress (route exists) — DOCUMENTED FAIL (https enforcement)", { timeout: 60_000 }, async () => {
  const cred = new ClientSecretCredential(TENANT, CLIENT, SECRET, { authorityHost: ARM_TLS });
  const { outcome, detail } = await (async () => {
    try {
      const kc = new KeyClient(`http://127.0.0.1:${PORTS.egress}`, cred);
      const key = await kc.getKey("ts-court-byok", { allowInsecureConnection: true, abortSignal: T(45_000) });
      return { outcome: "resolved", detail: `kid=${key.id}` };
    } catch (err) {
      return { outcome: "rejected", detail: `${err.name}: ${err.message}` };
    }
  })();
  if (outcome === "rejected") {
    assert.fail(
      `DOCUMENTED FAIL — KeyClient.getKey against the http egress got ${detail}. ` +
      `Limitation: azidentity/KeyVault enforce https for Key Vault endpoints and the substrate's Key Vault ` +
      `data plane is http-only (no TLS on :${PORTS.egress}); per-call allowInsecureConnection does not lift it. ` +
      `Verified even though the GET /keys/:name route exists on the egress plane.`,
    );
  }
});

test("byok skr raw REST: create key w/ release policy → MAA attest → release 200; garbage bearer → 403; no auth → 403", { timeout: 60_000 }, async () => {
  const keyName = `ts-court-byok-${Date.now()}`;
  const createRes = await fetch(`${EGRESS}/keys/${keyName}/create`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      kty: "RSA-HSM",
      release_policy: { allowed_operations: ["release"] },
    }),
    signal: T(20_000),
  });
  assert.equal(createRes.status, 200, `key create status ${createRes.status}`);
  const created = await createRes.json();
  assert.ok(created.kid, "created key has kid");
  assert.ok(created.release_policy, "release policy stored");

  const attestRes = await fetch(`${EGRESS}/attest/sevsnpvm`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ measurement: MEASUREMENT }),
    signal: T(20_000),
  });
  assert.equal(attestRes.status, 200, `attest status ${attestRes.status} (measurement must be in baseline)`);
  const { token: maaToken, claims } = await attestRes.json();
  assert.equal(claims["x-ms-compliance-status"], "azure-compliant-cvm", "MAA claims compliance status");
  const maaJwt = assertJwt(maaToken);
  assert.equal(maaJwt["x-ms-compliance-status"], "azure-compliant-cvm", "MAA JWT carries compliance claim");

  const releaseRes = await fetch(`${EGRESS}/keys/${keyName}/release`, {
    method: "POST",
    headers: { authorization: `Bearer ${maaToken}` },
    signal: T(20_000),
  });
  assert.equal(releaseRes.status, 200, `release with attested bearer → 200, got ${releaseRes.status}`);
  const released = await releaseRes.json();
  assert.equal(released.status, "Released", "release status Released");
  assert.ok(released.value, "released key material present");

  const badRes = await fetch(`${EGRESS}/keys/${keyName}/release`, {
    method: "POST",
    headers: { authorization: "Bearer not-a-jwt" },
    signal: T(20_000),
  });
  assert.equal(badRes.status, 403, `garbage bearer → 403, got ${badRes.status}`);

  const noAuthRes = await fetch(`${EGRESS}/keys/${keyName}/release`, {
    method: "POST",
    signal: T(20_000),
  });
  assert.equal(noAuthRes.status, 403, `no auth → 403, got ${noAuthRes.status}`);
});

// ---------------------------------------------------------------------------
// 3. Cosmos reality
// ---------------------------------------------------------------------------

test("cosmos sdk: databases.createIfNotExists (DOCUMENTED FAIL if control-plane routes missing)", { timeout: 60_000 }, async () => {
  const cosmos = new CosmosClient({
    endpoint: EGRESS,
    key: crypto.randomBytes(32).toString("hex"),
    retryOptions: { maxRetryAttemptCount: 0 },
    connectionPolicy: { enableEndpointsDiscovery: false },
  });
  let outcome = "resolved";
  let detail = "";
  try {
    await cosmos.databases.createIfNotExists({ id: `ts-court-db-${Date.now()}` }, { abortSignal: T(30_000) });
  } catch (err) {
    outcome = "rejected";
    detail = `${err.name || "Error"} code=${err.code} body=${JSON.stringify(err.body || {}).slice(0, 200)}`;
  }
  console.log(`[ts-reality] @azure/cosmos databases.createIfNotExists → ${outcome}: ${detail}`);
  if (outcome === "rejected") {
    assert.fail(
      `DOCUMENTED FAIL — @azure/cosmos cannot manage databases/containers against the substrate (${detail}). ` +
      `Limitation: the egress plane mounts only the docs routes (/dbs/:db/colls/:coll/docs); ` +
      `database/container control-plane routes (GET/POST /dbs, /dbs/:db, /dbs/:db/colls/:coll) are not mounted, ` +
      `so the SDK control plane 404s with RouteNotFound. Docs CRUD is exercised raw-REST below.`,
    );
  }
});

test("cosmos raw REST: docs CRUD over egress with conditional 304, stale If-Match 412, delete 204", { timeout: 60_000 }, async () => {
  const db = `ts-court-db-${Date.now()}`;
  const coll = "ts-court-coll";
  const pkHeader = { "x-ms-documentdb-partitionkey": '["court"]' };
  const docPath = `${EGRESS}/dbs/${db}/colls/${coll}/docs/ts-1`;

  const createRes = await fetch(`${EGRESS}/dbs/${db}/colls/${coll}/docs`, {
    method: "POST",
    headers: { "content-type": "application/json", ...pkHeader },
    body: JSON.stringify({ id: "ts-1", pk: "court", value: "héllo 🌊 reality" }),
    signal: T(20_000),
  });
  assert.equal(createRes.status, 201, `doc create 201, got ${createRes.status}`);
  const created = await createRes.json();
  assert.equal(created.value, "héllo 🌊 reality", "round-trip value equal");
  const etag = created._etag;
  assert.ok(etag, "doc has _etag");

  const getRes = await fetch(docPath, { headers: pkHeader, signal: T(20_000) });
  assert.equal(getRes.status, 200, "doc read 200");

  const notModRes = await fetch(docPath, {
    headers: { ...pkHeader, "if-none-match": etag },
    signal: T(20_000),
  });
  assert.equal(notModRes.status, 304, `conditional GET with current etag → 304, got ${notModRes.status}`);

  const staleRes = await fetch(docPath, {
    method: "PUT",
    headers: { "content-type": "application/json", ...pkHeader, "if-match": '"deadbeef"' },
    body: JSON.stringify({ id: "ts-1", pk: "court", value: "stale" }),
    signal: T(20_000),
  });
  assert.equal(staleRes.status, 412, `stale If-Match replace → 412, got ${staleRes.status}`);

  const goodRes = await fetch(docPath, {
    method: "PUT",
    headers: { "content-type": "application/json", ...pkHeader, "if-match": etag },
    body: JSON.stringify({ id: "ts-1", pk: "court", value: "v2" }),
    signal: T(20_000),
  });
  assert.equal(goodRes.status, 200, `current If-Match replace → 200, got ${goodRes.status}`);

  // Query wire shape is probed separately (documented fail below).

  const cur = await fetch(docPath, { headers: pkHeader, signal: T(20_000) });
  const curEtag = (await cur.json())._etag;
  const delRes = await fetch(docPath, {
    method: "DELETE",
    headers: { ...pkHeader, "if-match": curEtag },
    signal: T(20_000),
  });
  assert.equal(delRes.status, 204, `delete with If-Match → 204, got ${delRes.status}`);
});

test("cosmos query: POST application/query+json — real query result required (returns the seeded doc)", { timeout: 30_000 }, async () => {
  const db = `ts-court-qdb-${Date.now()}`;
  const pkHeader = { "x-ms-documentdb-partitionkey": '["court"]' };
  const seed = await fetch(`${EGRESS}/dbs/${db}/colls/c1/docs`, {
    method: "POST",
    headers: { "content-type": "application/json", ...pkHeader },
    body: JSON.stringify({ id: "seed-doc", pk: "court", value: "v" }),
    signal: T(20_000),
  });
  assert.equal(seed.status, 201, `seed doc create 201, got ${seed.status}`);

  const queryRes = await fetch(`${EGRESS}/dbs/${db}/colls/c1/docs`, {
    method: "POST",
    headers: { "content-type": "application/query+json", ...pkHeader },
    body: JSON.stringify({ query: "SELECT * FROM c" }),
    signal: T(20_000),
  });
  const queryBody = await queryRes.text();
  console.log(`[ts-reality] cosmos query+json POST → ${queryRes.status}: ${queryBody.slice(0, 160)}`);

  const isRealQueryResult =
    queryRes.status === 200 &&
    queryBody.includes("seed-doc") &&
    queryBody.includes("Documents");
  if (!isRealQueryResult) {
    assert.fail(
      `FAIL — POST application/query+json to /dbs/:db/colls/:coll/docs returned ` +
      `${queryRes.status}: ${queryBody.slice(0, 160)}. The seeded doc is not in the result set: ` +
      `the substrate query surface returns an empty Documents array (_count:0) for a partition ` +
      `whose doc exists (or stores the query as a doc). Real query semantics not witnessed.`,
    );
  }
});

// ---------------------------------------------------------------------------
// 4. Blob reality — SDK CRUD + WORM 409; legal hold via raw REST binding
// ---------------------------------------------------------------------------

const ACCOUNT = "smaltacct";
const ACCOUNT_KEY = "smaltacct-key";

test("blob sdk: container/blob CRUD round-trip + WORM overwrite 409", { timeout: 90_000 }, async () => {
  const service = new BlobServiceClient(
    `${EGRESS}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY),
  );
  const containerName = `ts-court-${Date.now()}`;
  const container = service.getContainerClient(containerName);
  await container.create({ abortSignal: T(30_000) });

  const blob = container.getBlockBlobClient("reality.txt");
  const content = Buffer.from("smalt reality court 🌊 multibyte", "utf8");
  const up = await blob.upload(content, content.length, { abortSignal: T(30_000) });
  assert.ok(up, "upload resolved");

  // GET-based download (downloadToBuffer issues HEAD first, which the
  // substrate's blob plane does not implement — recorded in the report).
  const dlRes = await blob.download(undefined, undefined, { abortSignal: T(30_000) });
  const chunks = [];
  for await (const chunk of dlRes.readableStreamBody) chunks.push(Buffer.from(chunk));
  const downloaded = Buffer.concat(chunks);
  assert.ok(downloaded.equals(content), "downloaded bytes equal uploaded bytes");

  // Raw signed-REST listing (SDK listBlobsFlat is a separate documented-fail probe below).
  // NOTE: the substrate's GET route checks restype=container before comp=list,
  // so restype must be omitted or the route answers container properties
  // instead of the blob listing.
  const listRes = await sharedKeyFetch(
    `${EGRESS}/${ACCOUNT}/${containerName}?comp=list`,
    "GET",
    ACCOUNT,
    ACCOUNT_KEY,
  );
  const listXml = await listRes.text();
  assert.equal(listRes.status, 200, `blob list status ${listRes.status}`);
  assert.ok(listXml.includes("reality.txt"), "listing includes the blob");

  // WORM: default container policy is immutable → overwrite 409.
  await assert.rejects(
    () => blob.upload(Buffer.from("second"), 6, { abortSignal: T(30_000) }),
    (err) => {
      assert.equal(err.statusCode, 409, `WORM overwrite → 409, got ${err.statusCode}`);
      return true;
    },
  );

  // WORM also blocks delete on the immutable container.
  await assert.rejects(
    () => blob.deleteIfExists({ abortSignal: T(30_000) }),
    (err) => {
      assert.equal(err.statusCode, 409, `WORM delete → 409 ContainerLocked, got ${err.statusCode}`);
      return true;
    },
  );
});

test("blob sdk: listBlobsFlat — DOCUMENTED FAIL (substrate list XML omits <Segment> wrapper)", { timeout: 60_000 }, async () => {
  const service = new BlobServiceClient(
    `${EGRESS}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY),
  );
  const containerName = `ts-court-list-${Date.now()}`;
  const container = service.getContainerClient(containerName);
  await container.create({ abortSignal: T(30_000) });
  await container.getBlockBlobClient("l.bin").upload(Buffer.from("l"), 1, { abortSignal: T(30_000) });

  let outcome = "resolved";
  let detail = "";
  try {
    const names = [];
    for await (const b of container.listBlobsFlat()) names.push(b.name);
    outcome = names.includes("l.bin") ? "resolved" : "empty";
    detail = `names=${JSON.stringify(names)}`;
  } catch (err) {
    outcome = "rejected";
    detail = `${err.name}: ${String(err.message).slice(0, 160)}`;
  }
  console.log(`[ts-reality] blob listBlobsFlat → ${outcome}: ${detail}`);
  if (outcome !== "resolved") {
    assert.fail(
      "DOCUMENTED FAIL - @azure/storage-blob listBlobsFlat cannot enumerate blobs: " + detail +
      ". Limitation: BlobStorage.list_blobs_xml/2 omits the <Segment> wrapper the JS SDK XML " +
      "mapper requires (ConvertInternalResponseOfListBlobFlat reads item.segment -> TypeError). " +
      "Raw signed-REST listing is asserted separately and works.",
    );
  }
});

test("blob legal hold via raw REST binding: set hold, overwrite blocked 409, clear hold", { timeout: 60_000 }, async () => {
  const containerName = `ts-court-hold-${Date.now()}`;
  const createRes = await sharedKeyFetch(
    `${EGRESS}/${ACCOUNT}/${containerName}`,
    "PUT",
    ACCOUNT,
    ACCOUNT_KEY,
    { "x-ms-immutable-policy": "false" },
  );
  assert.ok(
    createRes.status === 201 || createRes.status === 409,
    `container create (mutable) status ${createRes.status}`,
  );

  const service = new BlobServiceClient(
    `${EGRESS}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY),
  );
  const blob = service.getContainerClient(containerName).getBlockBlobClient("hold.bin");
  await blob.upload(Buffer.from("held"), 4, { abortSignal: T(30_000) });

  const holdRes = await sharedKeyFetch(
    `${EGRESS}/${ACCOUNT}/${containerName}?comp=legalhold`,
    "PUT",
    ACCOUNT,
    ACCOUNT_KEY,
    { "x-ms-legal-hold": "true" },
  );
  const holdBody = await holdRes.text();
  const holdSet =
    holdRes.status === 200 &&
    (holdRes.headers.get("x-ms-legal-hold") === "true" || holdBody.includes("has_legal_hold"));

  if (!holdSet) {
    assert.fail(
      `DOCUMENTED FAIL — raw REST PUT ?comp=legalhold returned ${holdRes.status}: ${holdBody.slice(0, 160)}. ` +
      `Limitation: the egress router has no ?comp=legalhold route — Smalt.DataPlane.BlobStorage.set_legal_hold/4 ` +
      `exists in the data plane but is mounted on no wire route; the guarded catch-all mis-dispatches the ` +
      `request (observed: it lands on container create). Legal-hold 409 semantics are unreachable over the wire.`,
    );
  }

  await assert.rejects(
    () => blob.upload(Buffer.from("blocked"), 7, { abortSignal: T(30_000) }),
    (err) => err.statusCode === 409,
    "overwrite under legal hold → 409",
  );

  const clearRes = await sharedKeyFetch(
    `${EGRESS}/${ACCOUNT}/${containerName}?comp=legalhold`,
    "PUT",
    ACCOUNT,
    ACCOUNT_KEY,
    { "x-ms-legal-hold": "false" },
  );
  assert.equal(clearRes.status, 200, "clear hold 200");
});

// ---------------------------------------------------------------------------
// 5. Service Bus reality — admin surface, sessions, dead-letter, lock renewal
// ---------------------------------------------------------------------------

const SB_CONN =
  `Endpoint=sb://127.0.0.1:${PORTS.amqp};SharedAccessKeyName=RootManageSharedAccessKey;` +
  `SharedAccessKey=${SB_KEY};UseDevelopmentEmulator=true`;

const SESSION_QUEUE = "ts-court-sessions";
const PLAIN_QUEUE = "ts-court-plain";

async function armCreateQueue(name, props) {
  // Parent namespace must exist (GraphLaw shape: flat "skuName" required).
  await fetch(
    `${ARM}/subscriptions/${SUB}/resourceGroups/ts-court-rg/providers/` +
      `Microsoft.ServiceBus/namespaces/ts-court-ns?api-version=2021-04-01`,
    {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ location: "smalt", skuName: "Standard" }),
      signal: T(30_000),
    },
  );
  const res = await fetch(
    `${ARM}/subscriptions/${SUB}/resourceGroups/ts-court-rg/providers/` +
      `Microsoft.ServiceBus/namespaces/ts-court-ns/queues/${name}?api-version=2021-04-01`,
    {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ location: "smalt", properties: props }),
      signal: T(30_000),
    },
  );
  return res;
}

test("sb admin: ServiceBusAdministrationClient.createQueue — SDK probe + raw ARM PUT fallback", { timeout: 90_000 }, async () => {
  const cred = new ClientSecretCredential(TENANT, CLIENT, SECRET, { authorityHost: ARM_TLS });
  let adminOutcome = "resolved";
  let adminDetail = "";
  try {
    const admin = new ServiceBusAdministrationClient(`https://localhost:${PORTS.armTls}`, cred);
    const q = await admin.createQueue(SESSION_QUEUE, { requiresSession: true }, { abortSignal: T(45_000) });
    adminDetail = `created ${q.name}`;
  } catch (err) {
    adminOutcome = "rejected";
    adminDetail = `${err.name}: ${String(err.message).slice(0, 160)} (statusCode=${err.statusCode ?? "n/a"})`;
  }
  console.log(`[ts-reality] ServiceBusAdministrationClient.createQueue → ${adminOutcome}: ${adminDetail}`);

  if (adminOutcome === "rejected") {
    const res = await armCreateQueue(SESSION_QUEUE, { requiresSession: true, lockDuration: "PT30S" });
    const body = await res.text();
    assert.equal(
      res.status,
      201,
      `raw ARM PUT queue fallback must succeed (status=${res.status}, body=${body.slice(0, 300)})`,
    );
  }

  const plain = await armCreateQueue(PLAIN_QUEUE, {});
  assert.ok([200, 201].includes(plain.status), `plain queue PUT status ${plain.status}`);
});

test("sb: non-session send/receive/complete round-trip", { timeout: 60_000 }, async () => {
  const client = new ServiceBusClient(SB_CONN, { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } });
  const sender = await client.createSender(PLAIN_QUEUE, { abortSignal: T(20_000) });
  try {
    const payload = `ts-court-plain-${Date.now()}-🌊`;
    await sender.sendMessages({ body: payload, messageId: "plain-1" }, { abortSignal: T(20_000) });
    const receiver = client.createReceiver(PLAIN_QUEUE, "peekLock");
    let msgs = [];
    try {
      msgs = await receiver.receiveMessages(1, { maxWaitTimeInMs: 6_000, abortSignal: T(12_000) });
    } catch (err) {
      await boundedClose(receiver);
      assert.fail(
        "DOCUMENTED FAIL - @azure/service-bus receiveMessages timed out against the substrate broker: " +
        err.name + ": " + String(err.message).slice(0, 160) +
        ". Limitation: the AMQP broker completes CBS auth, link attach and queue ensure, and the SDK send " +
        "resolves, but no delivery is ever produced on receiver-link flow credit (Smalt.Amqp.Connection " +
        "deliver_available/bump_credit path never dequeues). Send-side only on the wire today.",
      );
    }
    assert.equal(msgs.length, 1, "received exactly one message");
    assert.equal(msgs[0].body, payload, "payload round-trip equal");
    await msgs[0].complete({ abortSignal: T(12_000) });
    await boundedClose(receiver);
  } finally {
    await boundedClose(sender);
    await boundedClose(client);
  }
});

test("sb sessions: send w/ sessionId → acceptSession → renewLock → complete; deadLetter → DLQ drain", { timeout: 90_000 }, async () => {
  const client = new ServiceBusClient(SB_CONN, { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } });
  try {
    const sender = await client.createSender(SESSION_QUEUE, { abortSignal: T(20_000) });

    await sender.sendMessages(
      { body: "session-payload-1", sessionId: "S1", messageId: "s1-1" },
      { abortSignal: T(20_000) },
    );
    const sessionReceiver = await Promise.race([
      client.acceptSession(SESSION_QUEUE, "S1", {
        retryOptions: { maxRetries: 0, timeoutInMs: 10_000 },
      }),
      new Promise((_, reject) => setTimeout(() => reject(new Error("ACCEPT_SESSION_DEADLINE (12s)")), 12_000)),
    ]).catch((err) => {
      throw new Error(
        "DOCUMENTED FAIL - @azure/service-bus acceptSession never settles against the substrate: " +
        err.name + ": " + String(err.message).slice(0, 160) +
        ". Limitation: the session receiver link (com.microsoft:session-filter source) is never answered " +
        "with a delivering attach+flow by Smalt.Amqp.Connection, so the SDK open hangs. " +
        "Same receiver-delivery gap as the plain queue.",
      );
    });
    let s1msgs = [];
    try {
      s1msgs = await sessionReceiver.receiveMessages(1, { maxWaitTimeInMs: 6_000, abortSignal: T(12_000) });
    } catch (err) {
      await boundedClose(sessionReceiver);
      assert.fail(
        "DOCUMENTED FAIL - @azure/service-bus acceptSession succeeded but receiveMessages timed out: " +
        err.name + ": " + String(err.message).slice(0, 160) +
        ". Limitation: same receiver-delivery gap as the plain queue (no delivery on flow credit).",
      );
    }
    assert.equal(s1msgs.length, 1, "session S1 received one message");
    assert.equal(s1msgs[0].body, "session-payload-1", "session payload round-trip");
    assert.equal(s1msgs[0].sessionId, "S1", "sessionId preserved on receive");
    await s1msgs[0].renewLock({ abortSignal: T(12_000) });
    await s1msgs[0].complete({ abortSignal: T(12_000) });
    await boundedClose(sessionReceiver);

    await sender.sendMessages(
      { body: "session-payload-2", sessionId: "S2", messageId: "s2-1" },
      { abortSignal: T(20_000) },
    );
    const r2 = await client.acceptSession(SESSION_QUEUE, "S2", {
      retryOptions: { maxRetries: 0, timeoutInMs: 10_000 },
    });
    const s2msgs = await r2.receiveMessages(1, { maxWaitTimeInMs: 6_000, abortSignal: T(12_000) });
    assert.equal(s2msgs.length, 1, "session S2 received one message");
    await s2msgs[0].deadLetter({
      deadLetterReason: "ts-court",
      deadLetterErrorDescription: "court dead-letter probe",
    });
    await boundedClose(r2);

    const dlqReceiver = client.createReceiver(
      SESSION_QUEUE,
      "$DeadLetterQueue",
      { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } },
    );
    const dlq = await dlqReceiver.receiveMessages(1, { maxWaitTimeInMs: 6_000, abortSignal: T(12_000) });
    try {
      assert.equal(dlq.length, 1, "DLQ holds the dead-lettered message");
      assert.equal(dlq[0].body, "session-payload-2", "DLQ payload round-trip");
      await dlq[0].complete({ abortSignal: T(12_000) });
    } finally {
      await boundedClose(dlqReceiver);
    }
  } finally {
    await boundedClose(client);
  }
});

// ---------------------------------------------------------------------------
// 6. Event Hubs reality — producer/consumer round-trip on the EH lane
// ---------------------------------------------------------------------------

const EH_CONN =
  `Endpoint=sb://127.0.0.1:${PORTS.eh};SharedAccessKeyName=RootManageSharedAccessKey;` +
  `SharedAccessKey=${SB_KEY};EntityPath=ts-court-hub;UseDevelopmentEmulator=true`;

test("eventhubs: producer/consumer round-trip (getProperties, sendBatch, subscribe earliest)", { timeout: 45_000 }, async () => {
  const opts = { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } };
  const producer = new EventHubProducerClient(EH_CONN, opts);
  const consumer = new EventHubConsumerClient(
    EventHubConsumerClient.defaultConsumerGroupName,
    EH_CONN,
    opts,
  );
  const subscriptionHandles = [];
  try {
    let props;
    try {
      props = await Promise.race([
        producer.getEventHubProperties({ abortSignal: T(15_000) }),
        new Promise((_, reject) => setTimeout(() => reject(new Error("EH_MANAGEMENT_DEADLINE (15s)")), 15_000)),
      ]);
    } catch (err) {
      throw new Error(
        "DOCUMENTED FAIL - @azure/event-hubs getEventHubProperties timed out against the 5673 EH lane: " +
        err.name + ": " + String(err.message).slice(0, 160) +
        ". Limitation: the $management link is never answered on the EH lane (docs/WIRE_PARITY.md documents " +
        "the 5673 lane as PARTIAL: QueueStore semantics; management RPC has no responder), so SDK bootstrapping " +
        "cannot complete. Round-trip not witnessed on the wire.",
      );
    }
    assert.ok(Array.isArray(props.partitionIds) && props.partitionIds.length > 0,
      `partitionIds present (${JSON.stringify(props.partitionIds)})`);

    const sent = [`eh-court-${Date.now()}-a`, `eh-court-${Date.now()}-b`];
    const batch = await producer.createBatch({ abortSignal: T(20_000) });
    for (const body of sent) assert.ok(batch.tryAdd({ body }), "tryAdd");
    await producer.sendBatch(batch, { abortSignal: T(20_000) });

    const received = [];
    const sub = await consumer.subscribe(
      {
        processEvents: async (events) => {
          for (const e of events) received.push(String(e.body));
        },
        processError: async () => {},
      },
      { startPosition: { earliest: true }, maxWaitTimeInSeconds: 5 },
    );
    subscriptionHandles.push(sub);

    const deadline = Date.now() + 25_000;
    while (received.length < sent.length && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 500));
    }
    for (const body of sent) {
      assert.ok(received.includes(body), `consumer received "${body}" (got ${JSON.stringify(received).slice(0, 200)})`);
    }
  } finally {
    for (const h of subscriptionHandles) await boundedClose(h);
    await boundedClose(producer);
    await boundedClose(consumer);
  }
});
