// suites/blob.mjs — blob op list (max coverage of the Azure Blob REST
// surface through the official SDK). Identical code path for every target:
// the adapter hands in a BlobServiceClient; ops speak only the official SDK
// surface and return normalized records for the differ.
import { Buffer } from "node:buffer";

const statusOf = (res) => res?._response?.status ?? res?.statusCode ?? 200;

export async function runBlobSuite({ svc, runid }) {
  const cname = `parity${runid}`;
  const container = svc.getContainerClient(cname);
  const blob = container.getBlockBlobClient(`probe-${runid}`);
  const append = container.getAppendBlobClient(`append-${runid}`);
  const page = container.getPageBlobClient(`page-${runid}`);
  const staged = container.getBlockBlobClient(`staged-${runid}`);
  const body = `parity-payload-${runid}`;
  const recs = [];

  // Typed HTTP refusals become error records (parity data); only non-HTTP
  // failures propagate as crash/timeout to the runner's guard.
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

  // --- container surface -------------------------------------------------
  await op("container-create", async () => {
    const r = statusOf(await container.create());
    return { outcome: "ok", status: r, fields: {} };
  });

  await op("container-get-properties", async () => {
    const r = await container.getProperties();
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { hasMetadata: r.metadata !== undefined && r.metadata !== null },
    };
  });

  await op("container-set-metadata", async () => {
    const r = await container.setMetadata({ parity: runid });
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("container-get-metadata", async () => {
    const r = await container.getProperties();
    return { outcome: "ok", status: statusOf(r), fields: { parity: r.metadata?.parity ?? null } };
  });

  await op("service-properties-get", async () => {
    const r = await svc.getProperties();
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { corsIsArray: Array.isArray(r.cors), hasLogging: Boolean(r.logging) },
    };
  });

  await op("list-containers-prefix", async () => {
    const names = [];
    for await (const c of svc.listContainers({ prefix: cname })) names.push(c.name);
    return { outcome: "ok", status: 200, fields: { count: names.length, listed: names.includes(cname) } };
  });

  await op("container-lease-acquire-release", async () => {
    const lease = container.getBlobLeaseClient();
    const acq = await lease.acquireLease(15);
    const rel = await lease.releaseLease(acq.leaseId);
    return { outcome: "ok", status: statusOf(acq), fields: { hasLeaseId: Boolean(acq.leaseId), releaseStatus: statusOf(rel) } };
  });

  await op("container-set-access-policy", async () => {
    const r = await container.setAccessPolicy("blob", {
      accessPolicy: { permission: "r", expiresOn: new Date(Date.now() + 86_400_000) },
    });
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("container-get-access-policy", async () => {
    const r = await container.getAccessPolicy();
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { signedIdentifiersCount: (r.signedIdentifiers ?? []).length },
    };
  });

  // --- block blob surface ------------------------------------------------
  await op("block-upload", async () => {
    const r = await blob.upload(body, Buffer.byteLength(body));
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("blob-get-properties", async () => {
    const r = await blob.getProperties();
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { contentLength: r.contentLength },
    };
  });

  await op("blob-set-metadata", async () => {
    const r = await blob.setMetadata({ parity: runid });
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("blob-get-metadata", async () => {
    const r = await blob.getProperties();
    return { outcome: "ok", status: statusOf(r), fields: { parity: r.metadata?.parity ?? null } };
  });

  await op("blob-download", async () => {
    const r = await blob.download();
    const text = await streamText(r.readableStreamBody);
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { contentLength: r.contentLength, roundTrip: text === body },
    };
  });

  await op("blob-conditional-read-304", async () => {
    const props = await blob.getProperties();
    try {
      await blob.download(0, undefined, {
        conditions: { ifNoneMatch: props.etag },
      });
      return { outcome: "ok", status: 200, fields: { conditionNotHonored: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.errorCode ?? e?.code ?? null };
    }
  });

  await op("blob-set-http-headers", async () => {
    const r = await blob.setHTTPHeaders({ blobContentType: "text/plain" });
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("blob-content-type-after-headers", async () => {
    const r = await blob.getProperties();
    return { outcome: "ok", status: statusOf(r), fields: { contentType: r.contentType } };
  });

  await op("blob-list-flat", async () => {
    const names = [];
    const lengths = [];
    for await (const item of container.listBlobsFlat()) {
      names.push(item.name);
      lengths.push(item.properties.contentLength);
    }
    names.sort();
    return { outcome: "ok", status: 200, fields: { count: names.length, names, lengths } };
  });

  await op("blob-snapshot", async () => {
    const r = await blob.createSnapshot();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("snapshot-list-includes", async () => {
    const names = [];
    for await (const item of container.listBlobsFlat({ includeSnapshots: true })) {
      if (item.name === `probe-${runid}`) names.push(Boolean(item.snapshot));
    }
    return { outcome: "ok", status: 200, fields: { snapshotEntries: names.filter(Boolean).length } };
  });

  await op("blob-lease-acquire-release", async () => {
    const lease = blob.getBlobLeaseClient();
    const acq = await lease.acquireLease(15);
    const rel = await lease.releaseLease(acq.leaseId);
    return { outcome: "ok", status: statusOf(acq), fields: { hasLeaseId: Boolean(acq.leaseId), releaseStatus: statusOf(rel) } };
  });

  // --- append blob surface ----------------------------------------------
  await op("append-create", async () => {
    const r = await append.create();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("append-appendBlock", async () => {
    const r = await append.appendBlock(`appended-${runid}`, Buffer.byteLength(`appended-${runid}`));
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("append-download", async () => {
    const r = await append.download();
    const text = await streamText(r.readableStreamBody);
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { roundTrip: text === `appended-${runid}` },
    };
  });

  // --- page blob surface -------------------------------------------------
  await op("page-create", async () => {
    const r = await page.create(512);
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("page-upload", async () => {
    const r = await page.uploadPages(Buffer.alloc(512, "x"), 0, 512);
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("page-download", async () => {
    const r = await page.download();
    const buf = await streamText(r.readableStreamBody);
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: { contentLength: r.contentLength, allX: /^x+$/.test(buf) },
    };
  });

  // --- block staging surface --------------------------------------------
  // Block ids are base64 on the real wire ("YjE=" = "b1"); a non-base64 id
  // is refused by real Azure and (observed) accepted by smalt — the valid-id
  // path below is the scored op; the invalid-id refusal is its own op.
  const BLOCKID = "YjE=";
  await op("stage-block-uncommitted", async () => {
    const r = await staged.stageBlock(BLOCKID, `staged-${runid}`, Buffer.byteLength(`staged-${runid}`));
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("stage-block-invalid-id", async () => {
    try {
      await staged.stageBlock("not-base64!!", "x", 1);
      return { outcome: "ok", status: 201, fields: { invalidIdAccepted: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.errorCode ?? e?.code ?? null };
    }
  });

  await op("get-blocklist-uncommitted", async () => {
    const r = await staged.getBlockList("all");
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: {
        committedCount: (r.committedBlocks ?? []).length,
        uncommittedCount: (r.uncommittedBlocks ?? []).length,
      },
    };
  });

  await op("commit-blocklist", async () => {
    const r = await staged.commitBlockList([BLOCKID]);
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("get-blocklist-committed", async () => {
    const r = await staged.getBlockList("all");
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: {
        committedCount: (r.committedBlocks ?? []).length,
        uncommittedCount: (r.uncommittedBlocks ?? []).length,
      },
    };
  });

  // --- WORM surface (deletion under lock) -------------------------------
  await op("blob-delete-under-immutable", async () => {
    try {
      await blob.delete();
      return { outcome: "ok", status: 202, fields: { unexpectedlyDeleted: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.errorCode ?? e?.code ?? null };
    }
  });

  // --- teardown ----------------------------------------------------------
  await op("blob-delete", async () => {
    const r = await blob.delete();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("blob-download-after-delete", async () => {
    try {
      await blob.download();
      return { outcome: "ok", status: 200, fields: { unexpectedlyPresent: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.errorCode ?? e?.code ?? null };
    }
  });

  await op("container-delete", async () => {
    const r = statusOf(await container.delete().catch((e) => e));
    return { outcome: r >= 400 ? "error" : "ok", status: r, fields: {} };
  });

  await op("container-list-gone", async () => {
    const names = [];
    for await (const c of svc.listContainers()) names.push(c.name);
    return { outcome: "ok", status: 200, fields: { stillListed: names.includes(cname) } };
  });

  return { suite: "blob", records: recs };
}

async function streamText(stream) {
  if (!stream) return "";
  let out = "";
  for await (const chunk of stream) out += chunk.toString();
  return out;
}
