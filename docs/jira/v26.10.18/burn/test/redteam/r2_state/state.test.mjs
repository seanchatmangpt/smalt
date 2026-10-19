// r2_state — adversarial state/isolation redteam over the live smalt substrate.
// Scenarios: S1 isolation (subscription/RG/Cosmos namespace), S2 lifecycle
// races (PUT+DELETE, PUT-during-LRO, RG-delete cascade), S3 conditional
// TOCTOU, S4 name squatting, S5 LRO abuse, S6 ledger concurrency.
// Every 5xx / lost update / cross-scope leak is a FINDING.
import assert from "node:assert/strict";
import { test, before } from "node:test";
import crypto from "node:crypto";

const ARM = `http://127.0.0.1:${process.env.R2_ARM_PORT || 39443}`;
const DATA = `http://127.0.0.1:${process.env.R2_DATA_PORT || 38443}`;
const SUB_A = "11111111-1111-1111-1111-111111111111";
const SUB_B = "22222222-2222-2222-2222-222222222222";
const APIV = "2021-04-01";

let BEARER = null;
before(async () => {
  // Enforce-mode substrate: mint a token from the substrate's own STS.
  const res = await fetch(`${ARM}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "r2-state-redteam",
      client_secret: "irrelevant-dev-mode",
      scope: "https://management.azure.com/.default",
    }),
    signal: AbortSignal.timeout(30_000),
  });
  assert.equal(res.status, 200, `STS token issuance failed: ${res.status}`);
  BEARER = (await res.json()).access_token;
  assert.ok(BEARER, "access_token present");
});

function receipt(scenario, status, detail) {
  const r = { scenario, status: status, detail, at: new Date().toISOString() };
  console.log("RECEIPT " + JSON.stringify(r));
}

async function req(base, method, path, { body, headers } = {}) {
  const res = await fetch(base + path, {
    method,
    headers: {
      ...(BEARER ? { authorization: `Bearer ${BEARER}` } : {}),
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
      ...(headers || {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* empty or non-json */ }
  return { status: res.status, headers: res.headers, text, json };
}

function armPath(...segs) {
  return (
    `/subscriptions/${segs[0]}/resourceGroups/${encodeURIComponent(segs[1])}` +
    `/providers/${segs.slice(2).join("/")}` +
    `?api-version=${APIV}`
  );
}

async function putResource(sub, rg, type, ns, name, props = {}) {
  return req(ARM, "PUT", armPath(sub, rg, ns, type, name), {
    body: { location: "eastus", skuName: "standard", properties: props },
  });
}
async function getResource(sub, rg, ns, type, name) {
  return req(ARM, "GET", armPath(sub, rg, ns, type, name));
}
async function delResource(sub, rg, ns, type, name) {
  return req(ARM, "DELETE", armPath(sub, rg, ns, type, name));
}

async function putRG(sub, rg, location = "eastus") {
  return req(ARM, "PUT",
    `/subscriptions/${sub}/resourceGroups/${encodeURIComponent(rg)}?api-version=${APIV}`,
    { body: { location } });
}
async function getRG(sub, rg) {
  return req(ARM, "GET",
    `/subscriptions/${sub}/resourceGroups/${encodeURIComponent(rg)}?api-version=${APIV}`);
}
async function listRG(sub) {
  return req(ARM, "GET", `/subscriptions/${sub}/resourcegroups?api-version=${APIV}`);
}

function assertNo5xx(label, rsps) {
  for (const r of rsps) {
    assert.ok(r.status < 500,
      `${label}: got ${r.status} (5xx) body=${r.text.slice(0, 300)}`);
  }
}

async function pollOp(sub, opId, { timeoutMs = 25_000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const poll = await req(ARM, "GET", `/subscriptions/${sub}/operations/${opId}`);
    if (poll.json && poll.json.status === "Succeeded") return poll.json;
    if (Date.now() > deadline) return poll.json;
    await new Promise((r) => setTimeout(r, 500));
  }
}

// ===========================================================================
// S1 — ISOLATION: subscription, resource-group, and Cosmos namespace scoping
// ===========================================================================
test("S1: cross-subscription GET/LIST isolation (resources under A invisible to B)", async () => {
  const RG = "iso-rg-a";
  const rgPut = await putRG(SUB_A, RG);
  assert.ok([200, 201].includes(rgPut.status), `RG PUT ${rgPut.status}: ${rgPut.text.slice(0, 200)}`);
  const seed = await putResource(SUB_A, RG, "vaults", "Microsoft.KeyVault", "iso-vault-a");
  assert.ok([200, 201].includes(seed.status), `seed vault PUT ${seed.status}: ${seed.text.slice(0, 200)}`);

  // B-scoped reads by crafting paths with A's names under B's subscription.
  const getB = await getResource(SUB_B, RG, "Microsoft.KeyVault", "vaults", "iso-vault-a");
  assert.equal(getB.status, 404,
    `cross-sub GET must 404, got ${getB.status}: ${getB.text.slice(0, 200)}`);

  const listB = await listRG(SUB_B);
  assert.equal(listB.status, 200);
  const namesB = (listB.json?.value || []).map((x) => x.name);
  assert.ok(!namesB.includes(RG),
    `cross-sub RG LIST leaked: ${JSON.stringify(namesB)}`);

  const provB = await req(ARM, "GET",
    `/subscriptions/${SUB_B}/providers?api-version=${APIV}`);
  assert.equal(provB.status, 200);
  const leaked = (provB.json?.resourceTypes || [])
    .filter((rt) => (rt.resourceType || "").startsWith("vaults"));
  assert.equal(leaked.length, 0, `cross-sub provider inventory leaked vaults: ${JSON.stringify(leaked)}`);

  // Case-variant subscription id: store keys are fully downcased, so "SUB_A"
  // aliases A's namespace. PIN the actual — aliasing is a known-gap (squatting).
  const upper = await getResource(SUB_A.toUpperCase(), RG, "Microsoft.KeyVault", "vaults", "iso-vault-a");
  assert.ok(upper.status === 404 || upper.status === 200,
    `pin case-variant sub id: unexpected ${upper.status}`);
  receipt("S1", upper.status === 200 ? "KNOWN-GAP" : "PASS",
    `cross-sub GET 404; cross-sub RG/provider LIST clean; ` +
    `case-variant subscription id (uppercased) resolves A's resource -> ${upper.status} ` +
    `(store keys fully downcased: subscription ids alias across case)`);
});

test("S1b: cross-RG isolation within one subscription", async () => {
  await putRG(SUB_A, "iso-rg-x");
  await putRG(SUB_A, "iso-rg-y");
  const seed = await putResource(SUB_A, "iso-rg-x", "vaults", "Microsoft.KeyVault", "iso-vault-x");
  assert.ok([200, 201].includes(seed.status), `seed PUT ${seed.status}: ${seed.text.slice(0, 200)}`);

  const viaY = await getResource(SUB_A, "iso-rg-y", "Microsoft.KeyVault", "vaults", "iso-vault-x");
  assert.equal(viaY.status, 404, `cross-RG GET must 404, got ${viaY.status}`);

  const listY = await req(ARM, "GET",
    `/subscriptions/${SUB_A}/resourceGroups/iso-rg-y/providers/Microsoft.KeyVault/vaults?api-version=${APIV}`);
  assert.equal(listY.status, 200);
  assert.equal((listY.json?.value || []).length, 0,
    `cross-RG LIST leaked: ${JSON.stringify(listY.json?.value)}`);

  receipt("S1b", "PASS", "cross-RG GET 404 and type LIST empty for sibling RG");
});

test("S1c: Cosmos db/coll namespace isolation and id collisions across dbs", async () => {
  const mk = (db) => req(DATA, "POST", `/dbs/${db}/colls/coll1/docs`, {
    body: { id: "shared-id", value: `from-${db}` },
  });
  const c1 = await mk("db1");
  assert.equal(c1.status, 201, `create db1: ${c1.status} ${c1.text.slice(0, 200)}`);
  const c2 = await mk("db2");
  assert.equal(c2.status, 201, `create db2: ${c2.status} ${c2.text.slice(0, 200)}`);

  const r1 = await req(DATA, "GET", "/dbs/db1/colls/coll1/docs/shared-id");
  const r2 = await req(DATA, "GET", "/dbs/db2/colls/coll1/docs/shared-id");
  assert.equal(r1.status, 200);
  assert.equal(r2.status, 200);
  assert.notEqual(r1.json?.value, r2.json?.value,
    "same doc id in two dbs must not collapse into one record");
  assert.equal(r1.json?.value, "from-db1");
  assert.equal(r2.json?.value, "from-db2");

  // Cross-namespace read via a coll that never held the id must 404.
  const cross = await req(DATA, "GET", "/dbs/db2/colls/coll2/docs/shared-id");
  assert.equal(cross.status, 404, `cross-namespace read must 404, got ${cross.status}`);

  // PIN: db-name casing — DB1 vs db1.
  const upper = await req(DATA, "GET", "/dbs/DB1/colls/coll1/docs/shared-id");
  assert.ok(upper.status === 404 || upper.status === 200,
    `unexpected DB1 read status ${upper.status}`);
  receipt("S1c", upper.status === 404 ? "PASS" : "PINNED",
    `db1/db2 namespaces isolated, same id across dbs distinct; DB1-cased read -> ${upper.status} (pinned)`);
});

// ===========================================================================
// S2 — LIFECYCLE RACES
// ===========================================================================
test("S2a: 20x parallel PUT+DELETE same resource — no 5xx, consistent terminal state", async () => {
  const NS = "Microsoft.KeyVault", T = "vaults", NAME = "race-vault";
  await putRG(SUB_A, "race-rg");

  const rounds = [];
  for (let i = 0; i < 20; i++) {
    rounds.push(Promise.all([
      putResource(SUB_A, "race-rg", T, NS, NAME),
      delResource(SUB_A, "race-rg", NS, T, NAME),
    ]));
  }
  const results = await Promise.all(rounds);
  const all = results.flat();
  assertNo5xx("PUT+DELETE race", all);

  for (const r of all) {
    assert.ok([200, 201, 404].includes(r.status),
      `unexpected status ${r.status} in PUT+DELETE race: ${r.text.slice(0, 200)}`);
  }

  const final = await getResource(SUB_A, "race-rg", NS, T, NAME);
  assert.ok([200, 404].includes(final.status),
    `terminal GET must be 200 or 404, got ${final.status}`);
  if (final.status === 200) {
    assert.equal(final.json.id.toLowerCase(),
      `/subscriptions/${SUB_A}/resourcegroups/race-rg/providers/microsoft.keyvault/vaults/${NAME}`);
  }
  receipt("S2a", "PASS",
    `40 racing requests ok (${all.filter((r) => r.status >= 200 && r.status < 300).length} 2xx), ` +
    `terminal GET ${final.status}, id consistent`);
});

test("S2b: PUT during LRO pending — second PUT while first op InProgress (pin semantics)", async () => {
  const NAME = "lro-acct-dup";
  const first = await req(ARM, "PUT", armPath(SUB_A, "race-rg", "Microsoft.Storage", "storageAccounts", NAME),
    { body: { location: "eastus", skuName: "Standard_LRS", properties: {} } });
  assert.equal(first.status, 202, `first PUT should be 202 LRO, got ${first.status}: ${first.text.slice(0, 200)}`);
  const opId = (first.headers.get("azure-asyncoperation") || "").split("/").pop();
  assert.ok(opId, "azure-asyncoperation header present");

  const second = await req(ARM, "PUT", armPath(SUB_A, "race-rg", "Microsoft.Storage", "storageAccounts", NAME),
    { body: { location: "westus", skuName: "Standard_LRS", properties: {} } });
  assertNo5xx("PUT-during-LRO", [first, second]);
  assert.ok([200, 201, 202, 409, 412].includes(second.status),
    `second PUT during pending LRO returned ${second.status}: ${second.text.slice(0, 200)}`);

  const op = await pollOp(SUB_A, opId);
  assert.ok(op && op.status === "Succeeded", `first op never reached Succeeded: ${JSON.stringify(op)}`);
  receipt("S2b", "PINNED",
    `second PUT while op InProgress -> ${second.status} (no conflict detection); ` +
    `first op still completes Succeeded`);
});

test("S2c: DELETE parent RG with children present — cascade? (pin + orphan risk)", async () => {
  await putRG(SUB_A, "cascade-rg");
  await putResource(SUB_A, "cascade-rg", "vaults", "Microsoft.KeyVault", "cascade-vault");
  await putResource(SUB_A, "cascade-rg", "vaults", "Microsoft.KeyVault", "cascade-vault2");

  const del = await req(ARM, "DELETE",
    `/subscriptions/${SUB_A}/resourceGroups/cascade-rg?api-version=${APIV}`);
  assert.equal(del.status, 200, `RG delete: ${del.status}`);

  const orphan1 = await getResource(SUB_A, "cascade-rg", "Microsoft.KeyVault", "vaults", "cascade-vault");
  const orphan2 = await getResource(SUB_A, "cascade-rg", "Microsoft.KeyVault", "vaults", "cascade-vault2");
  assert.ok(orphan1.status === 200 || orphan1.status === 404,
    `pin child-after-RG-delete: ${orphan1.status}`);
  assert.equal(orphan1.status, orphan2.status, "both children same fate");

  const rgGet = await getRG(SUB_A, "cascade-rg");
  assert.equal(rgGet.status, 404, "RG itself must be gone");

  if (orphan1.status === 200) {
    receipt("S2c", "KNOWN-GAP",
      "RG DELETE does not cascade: children remain readable (200) while parent RG is 404 — orphan risk");
    await delResource(SUB_A, "cascade-rg", "Microsoft.KeyVault", "vaults", "cascade-vault");
    await delResource(SUB_A, "cascade-rg", "Microsoft.KeyVault", "vaults", "cascade-vault2");
  } else {
    receipt("S2c", "PASS", "RG DELETE cascades to children");
  }
});

// ===========================================================================
// S3 — CONDITIONAL TOCTOU: stale If-Match must never yield a lost update
// ===========================================================================
test("S3a: ARM resource stale If-Match PUT — pin (lost-update surface)", async () => {
  await putRG(SUB_A, "toctou-rg");
  await putResource(SUB_A, "toctou-rg", "vaults", "Microsoft.KeyVault", "toctou-vault", { v: 0 });

  const read = await getResource(SUB_A, "toctou-rg", "Microsoft.KeyVault", "vaults", "toctou-vault");
  const etagHeader = read.headers.get("etag");

  // Concurrent writer replaces the resource.
  const writer = await putResource(SUB_A, "toctou-rg", "vaults", "Microsoft.KeyVault", "toctou-vault", { v: 1 });
  assert.ok([200, 201].includes(writer.status),
    `concurrent writer PUT ${writer.status}: ${writer.text.slice(0, 200)}`);

  // Stale conditional PUT using the first representation's etag (or none, if none was issued).
  const stale = await req(ARM, "PUT", armPath(SUB_A, "toctou-rg", "Microsoft.KeyVault", "vaults", "toctou-vault"),
    {
      body: { location: "eastus", properties: { v: "STALE-WRITE" } },
      headers: { "if-match": etagHeader || '"no-etag-was-issued"' },
    });

  const after = await getResource(SUB_A, "toctou-rg", "Microsoft.KeyVault", "vaults", "toctou-vault");
  const lostUpdate = after.json?.properties?.v === "STALE-WRITE";

  assert.ok(stale.status < 500, `stale If-Match PUT -> ${stale.status}`);
  assert.equal(lostUpdate, false,
    "LOST UPDATE: stale conditional write clobbered the concurrent writer's v=1");

  receipt("S3a", lostUpdate ? "CRITICAL" : (etagHeader ? "PINNED" : "KNOWN-GAP"),
    `ARM resource GET ETag header=${JSON.stringify(etagHeader)}; stale If-Match PUT -> ${stale.status}; ` +
    `final v=${JSON.stringify(after.json?.properties?.v)} (${lostUpdate ? "LOST UPDATE" : "no lost update this run"})`);
});

test("S3b: Cosmos stale etag replace — 412 ALWAYS (100 iterations, zero lost updates)", async () => {
  let got412 = 0;
  const other = [];
  for (let i = 0; i < 100; i++) {
    const id = `toctou-${i}`;
    const created = await req(DATA, "POST", "/dbs/toctoudb/colls/c1/docs", {
      body: { id, v: 0 },
    });
    assert.equal(created.status, 201, `seed create ${i}: ${created.status} ${created.text.slice(0, 200)}`);
    const etag = created.json._etag;

    // concurrent (unconditional) replace changes the doc
    const repl = await req(DATA, "PUT", `/dbs/toctoudb/colls/c1/docs/${id}`, {
      body: { id, v: 1 },
    });
    assert.equal(repl.status, 200, `replace ${i}: ${repl.status}`);

    // stale conditional PUT must 412
    const stale = await req(DATA, "PUT", `/dbs/toctoudb/colls/c1/docs/${id}`, {
      body: { id, v: "STALE" },
      headers: { "if-match": etag },
    });
    if (stale.status === 412) got412++;
    else other.push({ i, status: stale.status, body: stale.text.slice(0, 200) });

    const after = await req(DATA, "GET", `/dbs/toctoudb/colls/c1/docs/${id}`);
    assert.equal(after.json?.v, 1,
      `LOST UPDATE at iter ${i}: final v=${JSON.stringify(after.json?.v)}`);
  }
  assert.equal(other.length, 0,
    `stale etag PUTs that did NOT 412: ${JSON.stringify(other.slice(0, 5))}`);
  assert.equal(got412, 100);
  receipt("S3b", "PASS", "100/100 stale-etag cosmos PUTs -> 412; zero lost updates");
});

// ===========================================================================
// S4 — NAME SQUATTING: case variants, whitespace, casing collisions
// ===========================================================================
test("S4: case-variant and whitespace resource names — pin store-key collision semantics", async () => {
  await putRG(SUB_A, "squ-rg");
  const cap = await putResource(SUB_A, "squ-rg", "vaults", "Microsoft.KeyVault", "Vault");
  assert.ok([200, 201].includes(cap.status), `Vault PUT ${cap.status}: ${cap.text.slice(0, 300)}`);
  const low = await putResource(SUB_A, "squ-rg", "vaults", "Microsoft.KeyVault", "vault");
  assert.ok([200, 201].includes(low.status), `vault PUT ${low.status}: ${low.text.slice(0, 300)}`);

  assert.ok([200, 201].includes(cap.status), `Vault PUT ${cap.status}`);
  assert.ok([200, 201].includes(low.status), `vault PUT ${low.status}`);

  const readCap = await getResource(SUB_A, "squ-rg", "Microsoft.KeyVault", "vaults", "Vault");
  const readLow = await getResource(SUB_A, "squ-rg", "Microsoft.KeyVault", "vaults", "vault");
  assert.equal(readCap.status, 200);
  assert.equal(readLow.status, 200);

  // PIN: the two casings resolve to ONE record (case-normalized store keys).
  assert.equal(readCap.json?.id, readLow.json?.id,
    `case variants resolved to different records: ${readCap.json?.id} vs ${readLow.json?.id}`);
  // Second (different-casing) PUT overwrites — no 409.
  assert.equal(low.status, 200, "second different-casing PUT should hit existing record (200)");

  // Whitespace names: leading/trailing spaces must not silently collide with the bare name.
  const sp = await putResource(SUB_A, "squ-rg", "vaults", "Microsoft.KeyVault", "%20vault%20");
  const spGet = await getResource(SUB_A, "squ-rg", "Microsoft.KeyVault", "vaults", "%20vault%20");
  assertNo5xx("whitespace name", [sp, spGet]);
  // PIN: accept admitted (200/201) or shape-refused (400) — either is safe; a
  // 200 that resolves to the bare-name record would be the unsafe outcome.
  assert.ok([200, 201, 400].includes(sp.status),
    `" vault " PUT ${sp.status}: ${sp.text.slice(0, 300)}`);
  if (sp.status === 400) {
    assert.equal(spGet.status, 404, `" vault " refused but GET -> ${spGet.status}`);
  }
  const collides = spGet.status === 200 && spGet.json?.id === readLow.json?.id;
  assert.equal(collides, false,
    "LOST KEY COLLISION: whitespace-variant name resolved to the bare-name record");

  receipt("S4", "PINNED",
    `Vault/vault collapse to one record (id=${readCap.json?.id}); different-casing PUT -> ${low.status} (overwrite, no 409); ` +
    `"%20vault%20" -> PUT ${sp.status}, GET ${spGet.status}, collides-with-bare=${collides}`);
});

// ===========================================================================
// S5 — LRO ABUSE: cross-scope operation reads, delete-during-op
// ===========================================================================
test("S5a: poll operations route with another subscription's op id — pin cross-scope read", async () => {
  const putRes = await req(ARM, "PUT", armPath(SUB_A, "race-rg", "Microsoft.Storage", "storageAccounts", "xsub-acct"),
    { body: { location: "eastus", skuName: "Standard_LRS", properties: {} } });
  assert.equal(putRes.status, 202);
  const opId = (putRes.headers.get("azure-asyncoperation") || "").split("/").pop();

  const cross = await req(ARM, "GET", `/subscriptions/${SUB_B}/operations/${opId}`);
  assert.ok([200, 202, 404].includes(cross.status), `pin: unexpected ${cross.status}`);

  if (cross.status === 200 || cross.status === 202) {
    assert.equal(
      (cross.json?.resourceId || "").toLowerCase().includes(SUB_A), true,
      "returned op should still reference sub A");
    receipt("S5a", "KNOWN-GAP",
      `cross-subscription GET of sub A's operation via /subscriptions/${SUB_B}/operations/${opId} -> ${cross.status} ` +
      `(sub scoping not enforced on the operations route; op ids are 12-byte random hex)`);
  } else {
    receipt("S5a", "PASS", `cross-sub op read refused: ${cross.status}`);
  }
});

test("S5b: DELETE resource while op InProgress, then poll — pin", async () => {
  const putRes = await req(ARM, "PUT", armPath(SUB_A, "race-rg", "Microsoft.Storage", "storageAccounts", "delop-acct"),
    { body: { location: "eastus", skuName: "Standard_LRS", properties: {} } });
  assert.equal(putRes.status, 202);
  const opId = (putRes.headers.get("azure-asyncoperation") || "").split("/").pop();

  const del = await delResource(SUB_A, "race-rg", "Microsoft.Storage", "storageAccounts", "delop-acct");
  assert.ok([200, 202, 404].includes(del.status), `DELETE during op: ${del.status}`);

  const gone = await getResource(SUB_A, "race-rg", "Microsoft.Storage", "storageAccounts", "delop-acct");
  assert.equal(gone.status, 404,
    `PIN: GET of resource with create-op InProgress after DELETE -> ${gone.status}`);

  const op = await pollOp(SUB_A, opId);
  assert.ok(op, "op record vanished from store");
  assert.equal(op.status, "Succeeded",
    `PIN: op for deleted resource ends ${op.status} (no cancellation)`);
  receipt("S5b", "PINNED",
    `DELETE during InProgress create-op: DELETE ${del.status}, resource immediately 404, ` +
    `op still completes Succeeded — phantom-success operation for a deleted resource`);
});

// ===========================================================================
// S6 — LEDGER: 32-writer concurrency, monotonic tx ids, chain integrity, dup 409 race
// ===========================================================================
function sha256hex(s) {
  return crypto.createHash("sha256").update(s).digest("hex");
}
// Mirror of the Erlang-side canonicalization: recursively string-keyed maps,
// encoded with sorted keys, no whitespace (Jason sorts binary keys).
function canonicalJson(obj) {
  if (obj !== null && typeof obj === "object" && !Array.isArray(obj)) {
    const keys = Object.keys(obj).sort();
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + canonicalJson(obj[k])).join(",") + "}";
  }
  return JSON.stringify(obj);
}

test("S6a: 32 concurrent distinct appends — monotonic, unique, chain unbroken (recomputed)", async () => {
  const rsps = await Promise.all(
    Array.from({ length: 32 }, (_, i) =>
      req(DATA, "POST", "/app/transactions", { body: { i, payload: `tx-${i}` } })),
  );
  assertNo5xx("ledger 32 writers", rsps);
  const ok = rsps.filter((r) => r.status === 201);
  assert.equal(ok.length, 32,
    `expected 32x201, got ${rsps.map((r) => r.status).join(",")}: ${ok[0]?.text?.slice(0, 200)}`);

  const recpts = ok.map((r) => r.json);
  const txIds = recpts.map((r) => r.transactionId);
  assert.equal(new Set(txIds).size, 32, `duplicate tx ids: ${txIds.join(",")}`);

  const seqs = txIds.map((t) => parseInt(t.split(".")[0], 10));
  assert.equal(new Set(seqs).size, 32, "duplicate sequence numbers across concurrent appends");

  // chain integrity from the authoritative list endpoint
  const list = await req(DATA, "GET", "/app/transactions");
  assert.equal(list.status, 200);
  const chain = list.json;
  assert.ok(Array.isArray(chain) && chain.length >= 32, `list shape: ${typeof chain}`);

  const sorted = [...chain].sort((a, b) => parseInt(a.transactionId) - parseInt(b.transactionId));
  const zero = "0".repeat(64);
  let prev = zero;
  let broken = null;
  const prevHashSeen = new Map();
  let fork = null;
  for (const r of sorted) {
    if (prevHashSeen.has(r.prev_hash) && r.prev_hash !== zero) {
      fork = `prev_hash ${r.prev_hash.slice(0, 12)}… shared by ${prevHashSeen.get(r.prev_hash)} and ${r.transactionId}`;
      break;
    }
    prevHashSeen.set(r.prev_hash, r.transactionId);
    const expectData = sha256hex(canonicalJson(r.contents));
    if (r.data_hash !== expectData) { broken = `data_hash mismatch at ${r.transactionId}`; break; }
    if (r.prev_hash !== prev) { broken = `chain break at ${r.transactionId}: prev_hash=${r.prev_hash.slice(0, 16)}… expected=${prev.slice(0, 16)}…`; break; }
    const expectRoot = sha256hex(prev + r.data_hash);
    if (r.merkle_root !== expectRoot) { broken = `merkle_root mismatch at ${r.transactionId}`; break; }
    prev = r.merkle_root;
  }
  if (fork || broken) {
    receipt("S6a", "CRITICAL",
      `${fork || broken} — concurrent appends raced the prev_root read: ` +
      `the Merkle chain FORKED under a 32-writer race (two txs minted from the same prev root); ` +
      `chain is NOT an unbroken linear history under concurrency`);
    assert.fail(fork || broken);
    return;
  }
  receipt("S6a", "PASS", `32/32 201, unique seqs, chain recomputed end-to-end unbroken, roots unique`);
});

test("S6b: duplicate-content 409 holds under race (32 concurrent same-content writers)", async () => {
  const content = { dup: true, tag: "race-dup-probe" };
  const rsps = await Promise.all(
    Array.from({ length: 32 }, () =>
      req(DATA, "POST", "/app/transactions", { body: content })),
  );
  assertNo5xx("ledger dup race", rsps);
  const created = rsps.filter((r) => r.status === 201);
  const conflict = rsps.filter((r) => r.status === 409);
  assert.equal(created.length + conflict.length, 32,
    `unexpected statuses: ${rsps.map((r) => r.status).join(",")}`);
  assert.ok(created.length <= 1,
    `duplicate-content race admitted ${created.length} identical appends (lost dedup)`);
  receipt("S6b", created.length <= 1 ? "PASS" : "CRITICAL",
    `32 same-content concurrent appends -> ${created.length}x201 / ${conflict.length}x409`);
});
