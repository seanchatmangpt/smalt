"use strict";
// T3 cosmos.test.cjs — @azure/cosmos against the egress Cosmos NoSQL plane (8443).
// Zero installs: vendored SDK via SMALT_SDK_ROOT.
//
// Auth wiring (honest, documented): the SDK-tier substrate runs in
// auth_mode :anonymous (config/test.exs). The Cosmos JS SDK signs requests
// with its master key (real wire auth header present); injecting the smalt
// STS Bearer would require a pipeline policy the substrate does not consume,
// so the enforce-mode Bearer contract is covered by test/auth_enforce_test.exs
// and the arm.test.cjs rows against the enforce-mode twin (9444).
const assert = require("node:assert/strict");
const { test } = require("node:test");
const path = require("node:path");
const crypto = require("node:crypto");

const SDK_ROOT =
  process.env.SMALT_SDK_ROOT || (function(){ console.error("[sdk-smoke] set SMALT_SDK_ROOT to a node_modules dir containing @azure packages"); process.exit(3); })();
const { CosmosClient } = require(path.join(SDK_ROOT, "@azure/cosmos"));

const ENDPOINT = "http://127.0.0.1:8443";
const MASTER_KEY = crypto.randomBytes(32).toString("hex"); // 64 chars

function client() {
  return new CosmosClient({
    endpoint: ENDPOINT,
    key: MASTER_KEY,
    retryOptions: { maxRetryAttemptCount: 0 },
    connectionPolicy: { enableEndpointsDiscovery: false },
  });
}

test("cosmos: database/container create, item round-trip, stale etag 412, delete", async () => {
  const cosmos = client();
  const dbId = `smoke-db-${Date.now()}`;
  const { database } = await cosmos.databases.createIfNotExists({ id: dbId });
  const { container } = await database.containers.createIfNotExists({
    id: "smoke-coll",
    partitionKey: { paths: ["/pk"] },
  });

  // Item create/read round-trip.
  const item = {
    id: "smoke-item-1",
    pk: "smoke",
    value: "héllo 🌊 multibyte",
  };
  const created = await container.items.create(item);
  assert.equal(created.statusCode, 201, "item create 201");
  const read = await container.item(item.id, item.pk).read();
  assert.equal(read.statusCode, 200, "item read 200");
  assert.equal(read.resource.value, item.value, "round-trip value equal");
  const etag = read.resource._etag;
  assert.ok(etag, "item has _etag");

  // Replace v1->v2 unconditionally (no condition), then re-read to capture
  // the CURRENT etag. NOTE: @azure/cosmos v4 IGNORES the {ifMatchETag}
  // option — the SDK-correct form is accessCondition: { type: "IfMatch",
  // condition: <etag> } (witnessed live: ifMatchETag is silently dropped).
  const v2 = await container.item(item.id, item.pk).replace({ ...item, value: "v2" });
  const currentEtag = v2.resource._etag;
  assert.ok(currentEtag, "replace returns fresh _etag");

  // IfMatch with the CURRENT etag -> 200.
  const replaced = await container.item(item.id, item.pk).replace(
    { ...item, value: "v2b" },
    { accessCondition: { type: "IfMatch", condition: currentEtag } },
  );
  assert.equal(replaced.statusCode, 200, "IfMatch on current etag 200");

  // Replace with a STALE etag (v1's) -> 412.
  try {
    await container.item(item.id, item.pk).replace(
      { ...item, value: "v3" },
      { accessCondition: { type: "IfMatch", condition: etag } },
    );
    assert.fail("stale-etag replace must fail");
  } catch (err) {
    assert.equal(err.code, 412, `expected 412, got ${err.code}`);
  }

  // Bare delete (no If-Match) is legal -> 204. (If the substrate demanded
  // a match precondition on delete, this would 412.)
  const del = await container.item(item.id, item.pk).delete();
  assert.equal(del.statusCode, 204, "bare item delete 204");
});
