/**
 * Console client court: workspace/lib/azure/cosmos.ts over the real smalt
 * data plane (8443). Chicago discipline: real transport, real substrate,
 * assertions on final state. Requires a live substrate (enforce mode):
 *   just substrate-up
 * Exit 0 = PASS. Requires node >= 22 (native TS strip-types via tsc prepass
 * in scripts/run-cosmos-query-test.mjs or direct `just` recipe).
 *
 * Wire-proven pins asserted here:
 * - POST-create semantics; PUT is replace-only, 404 on missing id
 * - pk-mismatch create -> typed 400
 * - SELECT * FROM c whitelist -> green; WHERE -> typed 400 SyntaxError
 *   (GAP(cosmos-sql-translator-absent) SKIP-LOUD, registered, not faked)
 * - continuation-token pagination walk to exhaustion (1000 docs, 5 pks)
 * - throughput management -> typed SmaltCosmosGapError (no substrate surface)
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  SmaltCosmosClient,
  SmaltCosmosError,
  SmaltCosmosGapError,
  COSMOS_EGRESS_BASE,
  COSMOS_ARM_BASE,
} from "../lib/azure/cosmos";

const DOCS = 1000;
const PKS = ["pk-a", "pk-b", "pk-c", "pk-d", "pk-e"];
const DB = `lane525-db-${Date.now()}`;
const COLL = "lane525-coll";

let client: SmaltCosmosClient;

test("boot: client + STS mint + account read", async () => {
  const c = new SmaltCosmosClient({ egressBase: COSMOS_EGRESS_BASE, armBase: COSMOS_ARM_BASE });
  const token = await c.mintToken();
  assert.match(token, /^eyJ/, "STS minted a 3-segment JWT");
  client = new SmaltCosmosClient({
    egressBase: COSMOS_EGRESS_BASE,
    bearerToken: token,
  });
  const acct = await client.account();
  assert.equal(acct["id"], "smalt");
  assert.equal(acct["kind"], "DatabaseAccount");
});

test("provision: database + partitioned container create/list", async () => {
  await client.createDatabase(DB);
  const dbs = await client.listDatabases();
  assert.ok(dbs.some((d) => d["id"] === DB), "created db is listable");

  await client.createContainer(DB, COLL, ["/pk"]);
  const colls = await client.listContainers(DB);
  assert.ok(colls.some((c) => c["id"] === COLL), "created container is listable");
});

test("seed 1000 docs across 5 partition keys (POST batches)", async () => {
  const batches: Promise<unknown>[] = [];
  for (let i = 0; i < DOCS; i++) {
    const pk = PKS[i % PKS.length];
    batches.push(
      client.createDoc(DB, COLL, {
        id: `doc-${String(i).padStart(5, "0")}`,
        pk,
        lane: "lane525",
        n: i,
      }, { pk }),
    );
    // bounded concurrency: flush every 100
    if (batches.length === 100) {
      const settled = await Promise.allSettled(batches);
      const rejected = settled.filter((s) => s.status === "rejected");
      assert.equal(rejected.length, 0, `batch rejects: ${JSON.stringify(rejected.slice(0, 3))}`);
      batches.length = 0;
    }
  }
  if (batches.length) {
    const settled = await Promise.allSettled(batches);
    assert.equal(settled.filter((s) => s.status === "rejected").length, 0);
  }

  // receipt on final state: walk each partition feed to exhaustion
  for (const pk of PKS) {
    const docs = await client.queryAll(DB, COLL, "SELECT * FROM c", { pk });
    assert.equal(docs.length, DOCS / PKS.length, `partition ${pk} holds 200 docs`);
  }
});

test("paginated query: continuation walk to exhaustion totals 1000", async () => {
  const docs = await client.queryAll(DB, COLL, "SELECT * FROM c");
  assert.equal(docs.length, DOCS, "cross-partition query returns every doc");

  // explicit page-walk assertions: 100-page limit, token only on truncation
  let pages = 0;
  let total = 0;
  let continuation: string | undefined;
  do {
    const page = await client.query(DB, COLL, "SELECT * FROM c", { continuation });
    assert.ok(page.count <= 100, "page size within the substrate feed limit");
    total += page.count;
    pages++;
    continuation = page.continuation;
    assert.ok(pages < 100, "walk terminates");
  } while (continuation);
  assert.equal(total, DOCS);
  assert.equal(pages, 10, "1000 docs at limit 100 = 10 pages");
});

test("read-your-write per doc (sampled across all 5 partitions)", async () => {
  for (let i = 0; i < DOCS; i += 97) {
    const pk = PKS[i % PKS.length];
    const doc = await client.getDoc(DB, COLL, `doc-${String(i).padStart(5, "0")}`, pk);
    assert.equal(doc["id"], `doc-${String(i).padStart(5, "0")}`);
    assert.equal(doc["pk"], pk);
    assert.equal(doc["n"], i);
  }
});

test("pk-mismatch create -> typed 400", async () => {
  await assert.rejects(
    () =>
      client.createDoc(DB, COLL, { id: "mismatch-1", pk: "pk-a" }, { pk: "pk-b" }),
    (err: unknown) => {
      assert.ok(err instanceof SmaltCosmosError);
      assert.equal((err as SmaltCosmosError).status, 400);
      assert.equal((err as SmaltCosmosError).code, "BadRequest");
      return true;
    },
  );
});

test("replace via PUT updates the doc; PUT on missing id -> 404", async () => {
  await client.createDoc(DB, COLL, { id: "rep-1", pk: "pk-a", v: 1 }, { pk: "pk-a" });
  const updated = await client.replaceDoc(DB, COLL, "rep-1", { id: "rep-1", pk: "pk-a", v: 2 }, "pk-a");
  assert.equal(updated["v"], 2, "replace landed");
  const reread = await client.getDoc(DB, COLL, "rep-1", "pk-a");
  assert.equal(reread["v"], 2, "read-your-replace");

  await assert.rejects(
    () => client.replaceDoc(DB, COLL, "rep-missing", { id: "rep-missing", pk: "pk-a" }, "pk-a"),
    (err: unknown) => {
      assert.ok(err instanceof SmaltCosmosError);
      assert.equal((err as SmaltCosmosError).status, 404, "PUT is replace-only, never upsert");
      return true;
    },
  );
});

test("whitelist query green (SELECT * FROM c)", async () => {
  const page = await client.query(DB, COLL, "SELECT * FROM c", { pk: "pk-c" });
  assert.ok(page.count > 0);
  assert.equal(page.documents[0]["pk"], "pk-c", "partition-scoped feed");
});

test("WHERE clause -> typed 400 SyntaxError (SKIP-LOUD registered GAP)", async () => {
  // GAP(cosmos-sql-translator-absent): the substrate fails closed on
  // non-whitelisted SQL. The correct client behavior is the typed refusal —
  // this row is a registered divergence, asserted loudly, not papered over.
  await assert.rejects(
    () => client.query(DB, COLL, "SELECT * FROM c WHERE c.n < 10"),
    (err: unknown) => {
      assert.ok(err instanceof SmaltCosmosError, "typed SmaltCosmosError");
      const e = err as SmaltCosmosError;
      assert.equal(e.status, 400);
      assert.equal(e.code, "SyntaxError");
      console.log(
        `[SKIP-LOUD] GAP(cosmos-sql-translator-absent): WHERE refused as typed 400 SyntaxError (registered divergence)`,
      );
      return true;
    },
  );
});

test("partition-key range feed readable", async () => {
  const ranges = await client.listPartitionKeyRanges(DB, COLL);
  assert.ok(Array.isArray(ranges), "pkranges feed parsed");
});

test("throughput management -> typed gap (loud, never faked)", async () => {
  await assert.rejects(
    () => client.getThroughput(DB, COLL),
    (err: unknown) => {
      assert.ok(err instanceof SmaltCosmosGapError);
      assert.equal((err as SmaltCosmosGapError).gap, "cosmos-throughput-absent");
      console.log(
        `[SKIP-LOUD] GAP(cosmos-throughput-absent): no offers/throughput surface on the substrate`,
      );
      return true;
    },
  );
  await assert.rejects(() => client.updateThroughput(DB, COLL, 400), SmaltCosmosGapError);
});
