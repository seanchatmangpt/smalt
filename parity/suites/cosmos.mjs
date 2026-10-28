// suites/cosmos.mjs — cosmos op list, docs surface + control plane.
// Identical code path for every target (control-plane asymmetry is confined
// to the adapters). Item bodies are normalized to user fields; system
// properties are stripped by the differ.
const statusOf = (res) => res?.statusCode ?? res?._response?.status ?? 200;
const userFields = (resource) =>
  resource === undefined || resource === null
    ? null
    : { id: resource.id ?? null, v: resource.v ?? null };

export async function runCosmosSuite({ client, container, runid }) {
  const docId = `probe-${runid}`;
  const docId2 = `probe2-${runid}`;
  const item = container.item(docId, docId);
  const item2 = container.item(docId2, docId2);
  const recs = [];
  const op = async (name, fn) => {
    try {
      recs.push({ op: name, ...(await fn()) });
    } catch (e) {
      recs.push({
        op: name,
        outcome: "error",
        status: e?.statusCode ?? 0,
        code: e?.code ?? null,
        fields: { message: String(e?.message ?? "").slice(0, 160) },
      });
    }
  };

  // --- docs surface ------------------------------------------------------
  await op("item-upsert-create", async () => {
    const r = await container.items.upsert({ id: docId, v: 0 });
    return { outcome: "ok", status: statusOf(r), fields: { resource: userFields(r.resource) } };
  });

  await op("item-read", async () => {
    const r = await item.read();
    return { outcome: "ok", status: statusOf(r), fields: { resource: userFields(r.resource) } };
  });

  await op("item-read-missing", async () => {
    try {
      await container.item(`missing-${runid}`, `missing-${runid}`).read();
      return { outcome: "ok", status: 200, fields: { unexpectedlyPresent: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.code ?? null };
    }
  });

  await op("item-replace-fresh-etag", async () => {
    const cur = await item.read();
    const r = await item.replace({ id: docId, v: 1 }, {
      accessCondition: { type: "IfMatch", condition: cur.resource?._etag },
    });
    return { outcome: "ok", status: statusOf(r), fields: { resource: userFields(r.resource) } };
  });

  await op("item-replace-stale-etag", async () => {
    try {
      await item.replace({ id: docId, v: 2 }, {
        accessCondition: { type: "IfMatch", condition: '"00000000-0000-0000-0000-000000000000"' },
      });
      return { outcome: "ok", status: 200, fields: { preconditionNotEnforced: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.code ?? null };
    }
  });

  await op("item2-upsert-create", async () => {
    const r = await container.items.upsert({ id: docId2, v: 100 });
    return { outcome: "ok", status: statusOf(r), fields: { resource: userFields(r.resource) } };
  });

  await op("item-upsert-update", async () => {
    const r = await container.items.upsert({ id: docId, v: 2 });
    return { outcome: "ok", status: statusOf(r), fields: { resource: userFields(r.resource) } };
  });

  await op("item-patch", async () => {
    const r = await item.patch({ operations: [{ op: "replace", path: "/v", value: 3 }] });
    return { outcome: "ok", status: statusOf(r), fields: { resource: userFields(r.resource) } };
  });

  await op("item-delete-2", async () => {
    const r = await item2.delete();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("item-read-after-delete-2", async () => {
    try {
      await item2.read();
      return { outcome: "ok", status: 200, fields: { unexpectedlyPresent: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.code ?? null };
    }
  });

  // --- queries -----------------------------------------------------------
  await op("query-point", async () => {
    const r = await container.items
      .query({
        query: "SELECT * FROM c WHERE c.id = @id",
        parameters: [{ name: "@id", value: docId }],
      })
      .fetchAll();
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { count: r.resources.length, resources: r.resources.map(userFields) },
    };
  });

  await op("query-cross-partition", async () => {
    const r = await container.items.query("SELECT * FROM c").fetchAll();
    const resources = r.resources.map(userFields).sort((a, b) => String(a.id).localeCompare(String(b.id)));
    return { outcome: "ok", status: statusOf(r), fields: { count: r.resources.length, resources } };
  });

  await op("query-order-by", async () => {
    const r = await container.items.query("SELECT * FROM c ORDER BY c.v DESC").fetchAll();
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { firstId: r.resources[0]?.id ?? null, order: r.resources.map((x) => x.v) },
    };
  });

  await op("query-count", async () => {
    const r = await container.items.query("SELECT VALUE COUNT(1) FROM c").fetchAll();
    return { outcome: "ok", status: statusOf(r), fields: { value: r.resources[0] ?? null } };
  });

  await op("item-delete", async () => {
    const r = await item.delete();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("item-read-after-delete", async () => {
    try {
      await item.read();
      return { outcome: "ok", status: 200, fields: { unexpectedlyPresent: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.code ?? null };
    }
  });

  // --- db/coll control plane (expected-divergence zone: smalt mounts only
  // the docs engine, so control-plane routes 404 there) -------------------
  await op("db-create", async () => {
    const r = await client.databases.create({ id: `parity-cp-${runid}` });
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("db-read", async () => {
    const r = await client.database(`parity-cp-${runid}`).read();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("coll-create-ifnotexists", async () => {
    const r = await client
      .database(`parity-cp-${runid}`)
      .containers.createIfNotExists({ id: "cp", partitionKey: { paths: ["/id"], kind: "Hash" } });
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("db-delete", async () => {
    const r = await client.database(`parity-cp-${runid}`).delete();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  return { suite: "cosmos", records: recs };
}
