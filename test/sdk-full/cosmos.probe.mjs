// TS-3 lane: real @azure/cosmos SDK probe against smalt Cosmos NoSQL plane (8443).
import { CosmosClient } from "@azure/cosmos";
import crypto from "node:crypto";

const ENDPOINT = "http://127.0.0.1:8443";
const MASTER_KEY = crypto.randomBytes(32).toString("hex");
const results = [];
function rec(name, status, detail) { results.push({ name, status, detail }); console.log(`[${status}] ${name} — ${detail}`); }
const edesc = (e) => `code=${e?.code} body=${JSON.stringify(e?.body ?? "").slice(0, 200)} msg=${String(e?.message ?? "").slice(0, 250)}`;

const client = () => new CosmosClient({
  endpoint: ENDPOINT, key: MASTER_KEY,
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});
const cosmos = client();

const dbId = `ts3db-${Date.now()}`;
const { database } = await cosmos.databases.createIfNotExists({ id: dbId });
rec("db.createIfNotExists", "PASS", `database ${dbId} created (statusCode ${database.id ? "ok" : "?"})`);
const { container } = await database.containers.createIfNotExists({ id: "c1", partitionKey: { paths: ["/pk"] } });
rec("container.createIfNotExists", "PASS", "container c1 with /pk partition key");

// CRUD
const item = { id: "doc-1", pk: "p1", value: "héllo 🌊 multibyte", n: 1 };
const created = await container.items.create(item);
rec("item.create", created.statusCode === 201 ? "PASS" : "FAIL", `status ${created.statusCode}, etag ${created.resource?._etag}`);

const read = await container.item("doc-1", "p1").read();
rec("item.read", read.statusCode === 200 && read.resource.value === item.value ? "PASS" : "FAIL",
  `status ${read.statusCode}, value=${JSON.stringify(read.resource?.value)}, etag=${read.resource?._etag}`);
const etagV1 = read.resource._etag;

const rep = await container.item("doc-1", "p1").replace({ ...item, value: "v2" });
rec("item.replace(unconditional)", rep.statusCode === 200 ? "PASS" : "FAIL", `status ${rep.statusCode}, new etag ${rep.resource?._etag}`);
const etagV2 = rep.resource._etag;

const repC = await container.item("doc-1", "p1").replace({ ...item, value: "v2b" },
  { accessCondition: { type: "IfMatch", condition: etagV2 } });
rec("item.replace(IfMatch current)", repC.statusCode === 200 ? "PASS" : "FAIL", `status ${repC.statusCode}`);

let stale = { pass: false, detail: "" };
try {
  await container.item("doc-1", "p1").replace({ ...item, value: "v3" },
    { accessCondition: { type: "IfMatch", condition: etagV1 } });
  stale.detail = "NO ERROR — stale etag replace admitted (expected 412)";
} catch (e) {
  stale = { pass: e.code === 412, detail: `code=${e.code} body=${JSON.stringify(e.body ?? "").slice(0, 300)}` };
}
rec("item.replace(stale etag -> 412)", stale.pass ? "PASS" : "FAIL", stale.detail);

// delete stale-etag -> 412 first
let delStale = { pass: false, detail: "" };
try {
  await container.item("doc-1", "p1").delete({ accessCondition: { type: "IfMatch", condition: etagV1 } });
  delStale.detail = "NO ERROR — stale etag delete admitted (expected 412)";
} catch (e) {
  delStale = { pass: e.code === 412, detail: `code=${e.code} body=${JSON.stringify(e.body ?? "").slice(0, 300)}` };
}
rec("item.delete(stale etag -> 412)", delStale.pass ? "PASS" : "FAIL", delStale.detail);

// upsert
try {
  const ups = await container.items.upsert({ id: "doc-1", pk: "p1", value: "v4" });
  rec("item.upsert(existing)", ups.statusCode === 200 ? "PASS" : "FAIL", `status ${ups.statusCode} (200 = replaced)`);
} catch (e) { rec("item.upsert(existing)", "FAIL", `code=${e.code} body=${JSON.stringify(e.body ?? "").slice(0, 300)}`); }
try {
  const ups2 = await container.items.upsert({ id: "doc-new", pk: "p1", value: "fresh" });
  rec("item.upsert(new)", ups2.statusCode === 201 ? "PASS" : "FAIL", `status ${ups2.statusCode} (201 = created)`);
} catch (e) { rec("item.upsert(new)", "FAIL", `code=${e.code} body=${JSON.stringify(e.body ?? "").slice(0, 300)}`); }

// delete (bare) 204
const del = await container.item("doc-new", "p1").delete();
rec("item.delete(bare -> 204)", del.statusCode === 204 ? "PASS" : "FAIL", `status ${del.statusCode}`);

// SQL whitelist: admitted form
let wl = { pass: false, detail: "" };
try {
  const feed = await container.items.query("SELECT * FROM c").fetchAll();
  wl = { pass: Array.isArray(feed.resources) && feed.resources.length >= 1, detail: `returned ${feed.resources.length} docs, requestCharge=${feed.requestCharge}` };
} catch (e) {
  wl = { pass: false, detail: `code=${e.code} body=${JSON.stringify(e.body ?? String(e)).slice(0, 300)}` };
}
rec("query('SELECT * FROM c') admitted", wl.pass ? "PASS" : "FAIL", wl.detail);

// SQL whitelist: refused form
let rf = { pass: false, detail: "" };
try {
  const feed = await container.items.query("SELECT * FROM c WHERE c.pk = 'p1'").fetchAll();
  rf = { pass: false, detail: `NO ERROR — non-whitelisted query ADMITTED, returned ${feed.resources.length} docs (whitelist not enforced?)` };
} catch (e) {
  rf = { pass: e.code === 400, detail: `code=${e.code} body=${JSON.stringify(e.body ?? String(e)).slice(0, 400)}` };
}
rec("query(WHERE-clause) refused 400", rf.pass ? "PASS" : "FAIL", rf.detail);

// partition-scoped query (v4: query(sql, { partitionKey }))
try {
  const resp = await container.items.query("SELECT * FROM c", { partitionKey: "p1" }).fetchAll();
  const ok = resp.resources.length >= 1 && resp.resources.every(d => d.pk === "p1");
  rec("partition-scoped query", ok ? "PASS" : "FAIL", `returned ${resp.resources.length} docs, all pk=p1: ${resp.resources.every(d => d.pk === "p1")}`);
} catch (e) {
  rec("partition-scoped query", "FAIL", `code=${e.code} body=${JSON.stringify(e.body ?? String(e)).slice(0, 300)}`);
}

// pagination across >100 docs: seed via sequential creates (bulk is a recorded
// divergence — see bulk rows), then paginate with maxItemCount=25.
const seed = [];
for (let i = 0; i < 120; i++) seed.push({ id: `seq-${i}`, pk: "seq", i });
let seedOk = 0;
const t0 = Date.now();
try {
  for (const d of seed) {
    const r = await container.items.create(d);
    if (r.statusCode === 201) seedOk++;
  }
  rec("seed 120 docs (sequential create)", seedOk === 120 ? "PASS" : "FAIL", `${seedOk}/120 created in ${Date.now() - t0}ms`);
} catch (e) {
  rec("seed 120 docs (sequential create)", "FAIL", edesc(e));
}
// bulk upsert: single-partition batch (divergence probe)
try {
  const bulk = await container.items.bulk([0, 1, 2].map(i => ({ operationType: "Upsert", resourceBody: { id: `b-${i}`, pk: "seq" } })));
  const ok = bulk.filter(r => r.statusCode === 200 || r.statusCode === 201).length;
  rec("bulk upsert 3 ops (single partition)", ok === 3 ? "PASS" : "FAIL",
    `${ok}/3 ok; statuses ${bulk.map(r => r.statusCode).join(",")}; err=${JSON.stringify(bulk.filter(r => r.statusCode >= 400).map(r => r.e?.message ?? null)).slice(0, 220)}`);
} catch (e) {
  rec("bulk upsert 3 ops (single partition)", "FAIL", edesc(e));
}
// cross-partition bulk: 3 ops on 3 distinct pks in one call
try {
  const cross = await container.items.bulk([0, 1, 2].map(i => ({ operationType: "Upsert", resourceBody: { id: `x-${i}`, pk: `x-${i}` } })));
  const ok = cross.filter(r => r.statusCode === 200 || r.statusCode === 201).length;
  rec("bulk upsert cross-partition (3 pks)", ok === 3 ? "PASS" : "FAIL",
    `${ok}/3 ok; statuses ${cross.map(r => r.statusCode).join(",")}; err=${JSON.stringify(cross.filter(r => r.statusCode >= 400).map(r => r.e?.message ?? null)).slice(0, 220)}`);
} catch (e) {
  rec("bulk upsert cross-partition (3 pks)", "FAIL", edesc(e));
}

// paginate with small maxItemCount via continuation
try {
  const iterator = container.items.query("SELECT * FROM c", { maxItemCount: 25 });
  let pages = 0, total = 0, cont = undefined, firstCont = null;
  for (;;) {
    const resp = await iterator.fetchNext();
    pages++; total += resp.resources.length;
    cont = resp.continuationToken;
    if (pages === 1) firstCont = cont;
    if (!cont || pages > 20) break;
  }
  rec("pagination continuation (maxItemCount=25)", pages > 1 && total >= 120 ? "PASS" : "FAIL",
    `pages=${pages} totalDocs=${total} firstContinuation=${firstCont ? String(firstCont).slice(0, 40) + "…" : "NONE"}`);
} catch (e) {
  rec("pagination continuation (maxItemCount=25)", "FAIL", `code=${e.code} body=${edesc(e)}`);
}

// listing probes
try {
  for (let i = 0; i < 3; i++) await cosmos.databases.createIfNotExists({ id: `ts3list-${i}` });
  let dbResp = await cosmos.databases.readAll().fetchNext();
  const dbIds = dbResp.resources.map(d => d.id);
  rec("databases.list (readAll)", dbIds.includes(dbId) && dbIds.length >= 4 ? "PASS" : "FAIL", `databases=${dbIds.join(",")}`);
} catch (e) {
  rec("databases.list (readAll)", "FAIL", `code=${e.code} body=${edesc(e)}`);
}
try {
  const cResp = await database.containers.readAll().fetchAll();
  const conts = cResp.resources.map(c => c.id);
  rec("containers.list", conts.includes("c1") ? "PASS" : "FAIL", `containers=${conts.join(",")}`);
} catch (e) {
  rec("containers.list", "FAIL", `code=${e.code} body=${edesc(e)}`);
}

// cleanup
try { await database.delete(); } catch {}
for (let i = 0; i < 3; i++) { try { await cosmos.database(`ts3list-${i}`).delete(); } catch {} }

const fails = results.filter(r => r.status === "FAIL");
console.log(`\nSUMMARY: ${results.length - fails.length}/${results.length} PASS, ${fails.length} FAIL`);
process.exit(fails.length ? 1 : 0);
