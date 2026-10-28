// suites/table.mjs — Azure Table Storage op list. smalt has NO table plane
// (no module under lib/smalt/data_plane/; the egress router arms only the
// queue namespace before the blob splat). Every op here is expected to
// record smalt's no-route shape against Azurite's real answers — this
// suite exists to document that coverage gap loudly, per parity/README.md.
import { TableServiceClient, TableClient } from "@azure/data-tables";
import { AzureNamedKeyCredential } from "@azure/core-auth";

const statusOf = (res) => res?._response?.status ?? res?.statusCode ?? (res?.statusCode === undefined && res !== undefined ? 200 : 0);

export async function runTableSuite({ baseUrl, account, key, runid }) {
  const cred = new AzureNamedKeyCredential(account, key);
  // Table names are alphanumeric-only on the real service (no hyphens) —
  // Azurite enforces it, so the runid's hyphen is stripped.
  const tname = `parityt${runid.replace(/-/g, "")}`;
  const svc = new TableServiceClient(baseUrl, cred, {
    allowInsecureConnection: true,
    retryOptions: { maxRetries: 0 },
  });
  const table = new TableClient(baseUrl, tname, cred, {
    allowInsecureConnection: true,
    retryOptions: { maxRetries: 0 },
  });
  const pk = "parity";
  const recs = [];
  const op = async (name, fn) => {
    try {
      recs.push({ op: name, ...(await fn()) });
    } catch (e) {
      recs.push({
        op: name,
        outcome: "error",
        status: e?.statusCode ?? 0,
        code: e?.errorCode ?? e?.code ?? null,
        fields: { message: String(e?.message ?? "").slice(0, 160) },
      });
    }
  };

  await op("service-list-tables-empty", async () => {
    const names = [];
    for await (const t of svc.listTables()) names.push(t.name);
    return { outcome: "ok", status: 200, fields: { count: names.length } };
  });

  await op("table-create", async () => {
    const r = await svc.createTable(tname);
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("entity-insert", async () => {
    const r = await table.createEntity({ partitionKey: pk, rowKey: runid, value: "v0" });
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("entity-insert-duplicate", async () => {
    try {
      await table.createEntity({ partitionKey: pk, rowKey: runid, value: "dup" });
      return { outcome: "ok", status: 201, fields: { unexpectedlyDuplicated: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.errorCode ?? e?.code ?? null };
    }
  });

  await op("entity-get", async () => {
    const r = await table.getEntity(pk, runid);
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { partitionKey: r.partitionKey, rowKey: r.rowKey, value: r.value },
    };
  });

  await op("entity-upsert", async () => {
    const r = await table.upsertEntity({ partitionKey: pk, rowKey: runid, value: "v1" }, "Replace");
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("entity-get-after-upsert", async () => {
    const r = await table.getEntity(pk, runid);
    return { outcome: "ok", status: statusOf(r), fields: { value: r.value } };
  });

  await op("entity-query", async () => {
    const entities = [];
    for await (const e of table.listEntities()) entities.push({ value: e.value });
    return { outcome: "ok", status: 200, fields: { count: entities.length, values: entities.map((e) => e.value) } };
  });

  await op("entity-get-missing", async () => {
    try {
      await table.getEntity(pk, `missing-${runid}`);
      return { outcome: "ok", status: 200, fields: { unexpectedlyPresent: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.errorCode ?? e?.code ?? null };
    }
  });

  await op("entity-delete", async () => {
    const r = await table.deleteEntity(pk, runid);
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("table-delete", async () => {
    const r = await svc.deleteTable(tname);
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  return { suite: "table", records: recs };
}
