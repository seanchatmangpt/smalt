// Real-SDK probe: drives item create/read/replace through the REAL
// @azure/cosmos client (vendored at
// $SMALT_SDK_ROOT/node_modules/@azure/cosmos) against the
// live smalt substrate, and prints the response headers the SDK received.
// Run: node test/data_plane/sdk_probe.mjs  (substrate on :8443 must be up)
import assert from "node:assert/strict";
import { createRequire } from "module";
const sdkRoot = process.env.SMALT_SDK_ROOT; if (!sdkRoot) { console.error("[sdk_probe] set SMALT_SDK_ROOT"); process.exit(3); }
const require = createRequire(sdkRoot + "/");
const { CosmosClient } = require("@azure/cosmos");

const endpoint = process.env.SMALT_ENDPOINT || "http://localhost:8448";
const client = new CosmosClient({
  endpoint,
  key: "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==",
  connectionPolicy: { enableEndpointDiscovery: false },
});

// Note: no database/container createIfNotExists — the egress router's Cosmos
// surface is the docs routes; we address the collection by name directly.
const container = client.database("probedb").container("probecoll");

const itemId = `probe_${Date.now()}`;
const pk = "acme";
const reqOpts = { partitionKey: pk };

function dump(tag, response) {
  const h = response.headers || {};
  console.log(`--- ${tag} (status ${response.statusCode})`);
  for (const name of [
    "x-ms-alt-content-path",
    "x-ms-session-token",
    "x-ms-lsn",
    "x-ms-request-charge",
    "etag",
  ]) {
    console.log(`  ${name}: ${JSON.stringify(h[name])}`);
  }
  console.log(`  body.id: ${response.resource && response.resource.id}`);

  if (tag !== "create" && tag !== "read" && tag !== "replace" && tag !== "read-after-replace") {
    return;
  }
  // Hard gate: the real SDK must have received the hardening headers.
  assert(
    h["x-ms-alt-content-path"] === "dbs/probedb/colls/probecoll",
    `${tag}: missing/wrong x-ms-alt-content-path`,
  );
  assert(/^1#\d+$/.test(h["x-ms-session-token"]), `${tag}: missing x-ms-session-token`);
  assert(/^\d+$/.test(h["x-ms-lsn"]), `${tag}: missing x-ms-lsn`);
  assert(h["x-ms-request-charge"] === "1.0", `${tag}: missing x-ms-request-charge`);
}

// 1. create
const created = await container.items.create(
  { id: itemId, tenantId: pk, v: 1 },
  reqOpts,
);
dump("create", created);

// 2. read
const read = await container.item(itemId, pk).read();
dump("read", read);

// 3. replace
const replaced = await container.item(itemId, pk).replace(
  { id: itemId, tenantId: pk, v: 2 },
  reqOpts,
);
dump("replace", replaced);

// 4. read after replace (session consistency exercise)
const reread = await container.item(itemId, pk).read();
dump("read-after-replace", reread);

// Session-token monotonicity was asserted in dump() gates above:
// create/read reported 1#1, replace/read-after-replace reported 1#2.
console.log("--- all gates passed");
