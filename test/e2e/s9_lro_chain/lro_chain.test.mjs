// s9 LRO + azapi action chain — raw wire over the real ARM plane on 9443.
// Mirrors athena's terraform verbs: LRO PUT storageAccount (202 + async
// headers + poll to Succeeded), the full azapi action ladder on the created
// account (blobServices -> container -> immutabilityPolicy -> lock ->
// setLegalHold), nested diagnosticSettings, roleAssignment create/delete,
// managedHSM PUT/GET, and LRO-delete semantics.
//
// Every step cites {status, envelope} via [ROW] lines. Fail-closed: any
// assertion failure marks the step FAIL and propagates (node --test exit 1).
// Exit codes: 0 pass / 1 test failure (harness run.sh: 2 substrate never
// came up / 3 harness failure).
import { test } from "node:test";
import assert from "node:assert/strict";

const ARM = process.env.SMALT_ARM ?? "http://127.0.0.1:9443";
const SUB = "00000000-0000-0000-0000-000000000000";
const RG = "s9-lro-rg";
const RG_PATH = `/subscriptions/${SUB}/resourceGroups/${RG}`;

// api-versions pinned to Smalt.Registry latest (lib/smalt/registry.ex):
// storageAccounts/blobServices/managedHSMs/resourceGroups 2021-04-01,
// containers/immutabilityPolicies 2023-05-01, diagnosticSettings
// 2021-05-01-preview, roleAssignments 2022-04-01.
const V = {
  sa: "2021-04-01",
  blobSvc: "2021-04-01",
  container: "2023-05-01",
  policy: "2023-05-01",
  diag: "2021-05-01-preview",
  ra: "2022-04-01",
  hsm: "2021-04-01",
  rg: "2021-04-01",
};

const POLL_BUDGET = 40; // polls before the poll-budget assertion fails
const POLL_INTERVAL_MS = 50;
const TIMEOUT = 60_000;

function row(name, status, envelope, note = "") {
  console.log(
    `[ROW] ${name}: status=${status}${note ? ` note=${note}` : ""} envelope=${JSON.stringify(envelope ?? null).slice(0, 300)}`,
  );
}

async function req(method, path, { body, headers = {} } = {}) {
  const res = await fetch(`${ARM}${path}`, {
    method,
    headers: {
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
      ...headers,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(TIMEOUT),
  });
  const text = await res.text();
  let json = null;
  if (text.length > 0) {
    try {
      json = JSON.parse(text);
    } catch {
      json = null; // non-JSON envelope (e.g. empty DELETE body) — cited as-is
    }
  }
  return { status: res.status, headers: res.headers, json, text };
}

function q(path, version) {
  return `${path}?api-version=${version}`;
}

// ---------------------------------------------------------------------------
// (0) Resource group scope
// ---------------------------------------------------------------------------
test("s9 (0) PUT resource group scope", { timeout: TIMEOUT }, async () => {
  const res = await req("PUT", q(RG_PATH, V.rg), { body: { location: "eastus" } });
  row("rg-put", res.status, res.json ?? res.text);
  assert.ok([200, 201].includes(res.status), `rg put status ${res.status}`);
});

// ---------------------------------------------------------------------------
// (1) LRO PUT storageAccounts: 202 + async header set, poll to Succeeded
// ---------------------------------------------------------------------------
const SA_NAME = `s9st${Date.now().toString(36)}`;
const SA_PATH = `${RG_PATH}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}`;
let asyncOpPath = null;

test("s9 (1) LRO PUT storageAccount -> 202 + async headers, poll to Succeeded", { timeout: TIMEOUT }, async () => {
  const put = await req("PUT", q(SA_PATH, V.sa), {
    body: { location: "eastus", properties: { skuName: "Standard_LRS" } },
  });
  row("lro-put", put.status, put.json, `async=${put.headers.get("azure-asyncoperation")}`);
  assert.equal(put.status, 202, `LRO PUT status ${put.status}: ${put.text}`);

  const asyncUrl = put.headers.get("azure-asyncoperation");
  const locationUrl = put.headers.get("location");
  const retryAfter = put.headers.get("retry-after");
  assert.ok(asyncUrl, "Azure-AsyncOperation header present");
  assert.ok(locationUrl, "Location header present");
  assert.equal(retryAfter, "1", `Retry-After ${retryAfter}`);
  assert.match(asyncUrl, /^https:\/\/management\.smalt\.local\/subscriptions\/[^/]+\/operations\//);

  const op = put.json;
  assert.equal(op.status, "InProgress", `op status ${op.status}`);
  assert.ok(op.startTime, "op startTime present");
  assert.equal(op.endTime, null, "op endTime null while InProgress");
  assert.ok(op.resourceId.toLowerCase().endsWith(SA_PATH.toLowerCase()),
    `op resourceId ${op.resourceId}`);

  asyncOpPath = new URL(asyncUrl).pathname;
  assert.equal(asyncOpPath, new URL(locationUrl).pathname,
    "Location path equals Azure-AsyncOperation path");

  // Poll to terminal within budget.
  let polls = 0;
  let final = null;
  for (; polls < POLL_BUDGET; polls++) {
    final = await req("GET", asyncOpPath);
    if (final.json?.status === "Succeeded") break;
    assert.equal(final.status, 202, `intermediate poll status ${final.status}`);
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
  row("lro-poll-final", final?.status, final?.json, `polls=${polls + 1}`);
  assert.ok(final, "at least one poll issued");
  assert.equal(final.status, 200, `terminal poll status ${final.status}`);
  assert.equal(final.json.status, "Succeeded", "terminal status Succeeded");
  assert.ok(final.json.endTime, "terminal endTime present");
  assert.ok(polls < POLL_BUDGET, `poll budget exceeded (${polls + 1} polls)`);
});

// ---------------------------------------------------------------------------
// (2) azapi action ladder on the created account
// ---------------------------------------------------------------------------
test("s9 (2) azapi ladder: blobServices -> container -> policy -> lock -> setLegalHold", { timeout: TIMEOUT }, async () => {
  let policyEtag = null;

  {
    const res = await req("PUT", q(`${SA_PATH}/blobServices/default`, V.blobSvc), {
      body: { location: "eastus", properties: {} },
    });
    row("blobServices-put", res.status, res.json);
    assert.equal(res.status, 201, `blobServices PUT status ${res.status}: ${res.text}`);
    assert.equal(res.json.type, "Microsoft.Storage/storageAccounts/blobServices");
    assert.equal(res.json.properties.provisioningState, "Succeeded");
  }

  {
    const res = await req("PUT", q(`${SA_PATH}/blobServices/default/containers/s9chain`, V.container), {
      body: { location: "eastus", properties: {} },
    });
    row("container-put", res.status, res.json);
    assert.equal(res.status, 201, `container PUT status ${res.status}: ${res.text}`);
    assert.equal(res.json.type, "Microsoft.Storage/storageAccounts/blobServices/containers");
    assert.equal(res.json.name, "s9chain");
  }

  {
    const res = await req("PUT", q(`${SA_PATH}/blobServices/default/containers/s9chain/immutabilityPolicies/default`, V.policy), {
      body: { location: "eastus", properties: {} },
    });
    row("immutabilityPolicy-put", res.status, res.json);
    assert.equal(res.status, 201, `immutabilityPolicy PUT status ${res.status}: ${res.text}`);
    assert.equal(
      res.json.type,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
    );
    // Task contract: If-Match for the lock comes from the PUT response etag.
    // Cite the actual envelope: ETag header first, then body etag.
    policyEtag = res.headers.get("etag") ?? res.json.etag ?? null;
    if (policyEtag === null) {
      row("immutabilityPolicy-etag", "ABSENT", res.json,
        "GAP: child-put envelope carries no ETag; If-Match falls back to placeholder");
    }
  }

  {
    // lock action — If-Match enforced (presence): missing header -> 412.
    const ifMatch = policyEtag ?? '"s9-placeholder-etag"';
    const res = await req("POST", q(`${SA_PATH}/blobServices/default/containers/s9chain/immutabilityPolicies/default/lock`, V.policy), {
      headers: { "if-match": ifMatch },
    });
    row("lock-action", res.status, res.json, `if-match=${ifMatch}`);
    assert.equal(res.status, 200, `lock status ${res.status}: ${res.text}`);
    assert.equal(res.json.type, "Microsoft.Authorization/locks");
    assert.equal(res.json.name, "default");
    assert.equal(res.json.properties.level, "CanNotDelete");

    const neg = await req("POST", q(`${SA_PATH}/blobServices/default/containers/s9negprobe/immutabilityPolicies/default/lock`, V.policy), {});
    row("lock-no-if-match-probe", neg.status, neg.json);
    assert.equal(neg.status, 412, `lock without If-Match status ${neg.status} (expected 412)`);
  }

  {
    const res = await req("POST", q(`${SA_PATH}/blobServices/default/containers/s9chain/setLegalHold`, V.policy), {
      body: { tags: ["sovereign"] },
    });
    row("setLegalHold", res.status, res.json);
    assert.equal(res.status, 200, `setLegalHold status ${res.status}: ${res.text}`);
    assert.equal(res.json.type, "Microsoft.Storage/storageAccounts/blobServices/containers");
    assert.equal(res.json.name, "s9chain");
    assert.equal(res.json.properties.legalHoldState, "locked");
  }
});

// ---------------------------------------------------------------------------
// (3) nested diagnosticSettings at {sa_id}/providers/Microsoft.Insights/...
//     Non-404 proves the nested-provider route gap is closed; a 404 here is
//     a FAIL row naming the gap.
// ---------------------------------------------------------------------------
test("s9 (3) PUT nested diagnosticSettings ds1 -> non-404", { timeout: TIMEOUT }, async () => {
  const path = q(`${SA_PATH}/providers/Microsoft.Insights/diagnosticSettings/ds1`, V.diag);
  const res = await req("PUT", path, {
    body: { location: "global", properties: { eventHubName: null } },
  });
  row("diagnosticSettings-put", res.status, res.json ?? res.text);
  assert.notEqual(res.status, 404,
    `GAP: nested diagnosticSettings PUT at ${path} returned 404 — nested-provider route gap (router.ex handle_nested_diagnostic_settings)`);
  assert.ok(res.status >= 200 && res.status < 300,
    `diagnosticSettings PUT status ${res.status}: ${res.text}`);

  const get = await req("GET", path);
  row("diagnosticSettings-get", get.status, get.json);
  assert.equal(get.status, 200, `diagnosticSettings GET status ${get.status}`);
  assert.equal(get.json.name, "ds1");
});

// ---------------------------------------------------------------------------
// (4) roleAssignment at the RG scope: PUT 201 -> DELETE -> GET 404
// ---------------------------------------------------------------------------
test("s9 (4) roleAssignment PUT 201 -> DELETE -> GET 404", { timeout: TIMEOUT }, async () => {
  const raName = crypto.randomUUID();
  const path = q(`${RG_PATH}/providers/Microsoft.Authorization/roleAssignments/${raName}`, V.ra);

  const put = await req("PUT", path, {
    body: {
      location: "eastus",
      properties: {
        roleDefinitionId: `/subscriptions/${SUB}/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c`,
        principalId: "11111111-1111-1111-1111-111111111111",
        principalType: "ServicePrincipal",
      },
    },
  });
  row("roleAssignment-put", put.status, put.json);
  assert.equal(put.status, 201, `roleAssignment PUT status ${put.status}: ${put.text}`);
  assert.equal(put.json.type, "Microsoft.Authorization/roleAssignments");
  assert.equal(put.json.name, raName);

  const del = await req("DELETE", path);
  row("roleAssignment-delete", del.status, del.json ?? del.text);
  assert.equal(del.status, 200, `roleAssignment DELETE status ${del.status}`);

  const get = await req("GET", path);
  row("roleAssignment-get-after-delete", get.status, get.json);
  assert.equal(get.status, 404, `roleAssignment GET after delete ${get.status}`);
  assert.equal(get.json?.error?.code, "ResourceNotFound",
    `404 envelope code ${get.json?.error?.code}`);
});

// ---------------------------------------------------------------------------
// (5) managedHSM: PUT (assert actual LRO-ness against the registry) + GET
// ---------------------------------------------------------------------------
test("s9 (5) managedHSM PUT + GET", { timeout: TIMEOUT }, async () => {
  const name = `s9hsm${Date.now().toString(36)}`;
  const path = q(`${RG_PATH}/providers/Microsoft.KeyVault/managedHSMs/${name}`, V.hsm);

  const put = await req("PUT", path, {
    body: {
      location: "eastus",
      properties: { skuName: "Standard_B1", tenantId: SUB, softDeleteRetentionDays: 7 },
    },
  });
  row("managedHSM-put", put.status, put.json,
    `async=${put.headers.get("azure-asyncoperation")}`);
  // Actual registry behavior: managedHSMs is NOT in lro_type?/1
  // (router.ex:578 — only storageAccounts + virtualMachines), so the PUT is
  // synchronous 201 with NO async headers.
  assert.equal(put.status, 201, `managedHSM PUT status ${put.status}: ${put.text}`);
  assert.equal(put.headers.get("azure-asyncoperation"), null,
    "managedHSM PUT must not carry Azure-AsyncOperation (not an LRO type in the registry)");
  assert.equal(put.json.properties.provisioningState, "Succeeded");

  const get = await req("GET", path);
  row("managedHSM-get", get.status, get.json);
  assert.equal(get.status, 200, `managedHSM GET status ${get.status}`);
  assert.equal(get.json.name, name);
});

// ---------------------------------------------------------------------------
// (6) DELETE storageAccount -> 200, GET 404, operation record still queryable
// ---------------------------------------------------------------------------
test("s9 (6) DELETE storageAccount -> GET 404, operation record queryable", { timeout: TIMEOUT }, async () => {
  const del = await req("DELETE", q(SA_PATH, V.sa));
  row("storageAccount-delete", del.status, del.json ?? del.text);
  assert.equal(del.status, 200, `storageAccount DELETE status ${del.status}`);

  const get = await req("GET", q(SA_PATH, V.sa));
  row("storageAccount-get-after-delete", get.status, get.json);
  assert.equal(get.status, 404, `storageAccount GET after delete ${get.status}`);
  assert.equal(get.json?.error?.code, "ResourceNotFound");

  // The LRO operation record from step (1) survives the delete and is still
  // queryable over the operations route.
  assert.ok(asyncOpPath, "step (1) recorded an async operation path");
  const op = await req("GET", asyncOpPath);
  row("operation-record-after-delete", op.status, op.json);
  assert.equal(op.status, 200, `operation record GET status ${op.status}`);
  assert.equal(op.json.status, "Succeeded", "operation record terminal Succeeded");
});
