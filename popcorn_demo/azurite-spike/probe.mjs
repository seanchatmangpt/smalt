// W30-A interop spike — same @azure/storage-blob round trip against
// smalt TLS twin (https://127.0.0.1:9444, SharedKey per
// verification/ts/kd114-sharedkey.probe.cjs) and Azurite devstoreaccount1.
// Round trip: container create -> blob PUT -> list -> GET byte-equal -> delete.
"use strict";
import { BlobServiceClient, StorageSharedKeyCredential } from "@azure/storage-blob";
import crypto from "node:crypto";

const ACCOUNT_SMALT = "popcorn";
const KEY_SMALT =
  process.env.SMALT_SB_SHARED_KEY ||
  crypto.createHash("sha256").update(ACCOUNT_SMALT + "smalt-dev-sb").digest("base64");

const AZURITE_URL = "http://127.0.0.1:10100/devstoreaccount1";
const AZURITE_KEY =
  "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";

const backends = [
  {
    name: "smalt",
    url: "https://127.0.0.1:9444/" + ACCOUNT_SMALT,
    cred: new StorageSharedKeyCredential(ACCOUNT_SMALT, KEY_SMALT),
  },
  {
    name: "azurite",
    url: AZURITE_URL,
    cred: new StorageSharedKeyCredential("devstoreaccount1", AZURITE_KEY),
  },
];

const results = {};
const run = "";
const tag = Date.now();

for (const b of backends) {
  const rows = [];
  const svc = new BlobServiceClient(b.url, b.cred);
  const containerName = `w30a-container-${tag}`;
  const blobName = `w30a-blob-${tag}.txt`;
  const payload = Buffer.from(`w30a-bytes-${tag}`, "utf8");
  const step = async (op, fn) => {
    try {
      const r = await fn();
      const status = r?._response?.status ?? (r?.errorCode ? "?": 0);
      rows.push({ op, ok: true, status });
    } catch (e) {
      let body = "";
      try { body = JSON.stringify(e.response?.parsedBody ?? {}); } catch {}
      rows.push({ op, ok: false, status: e.statusCode ?? "n/a", err: (e.message || "").slice(0, 160), body: body.slice(0, 200) });
    }
  };

  const container = svc.getContainerClient(containerName);
  const blockBlob = container.getBlockBlobClient(blobName);

  await step("container-create", () => container.create());
  await step("blob-put", () => blockBlob.upload(payload, payload.length, { metadata: { w30a: "spike" } }));
  await step("list", async () => {
    const names = [];
    for await (const item of container.listBlobsFlat()) names.push(item.name);
    if (!names.includes(blobName)) throw Object.assign(new Error("blob not in list"), { statusCode: "LIST-MISS" });
    return { _response: { status: 200 } };
  });
  await step("get-byte-equal", async () => {
    const down = await container.getBlobClient(blobName).downloadToBuffer();
    if (Buffer.compare(payload, down) !== 0)
      throw Object.assign(new Error("byte mismatch"), { statusCode: "BYTE-MISMATCH" });
    return { _response: { status: 206 } };
  });
  await step("blob-delete", () => blockBlob.delete());
  await step("container-delete", () => container.delete());

  results[b.name] = rows;
}

console.log(JSON.stringify({ run, tag, results }, null, 2));
const allOk = Object.values(results).every((rows) => rows.every((r) => r.ok));
process.exit(allOk ? 0 : 1);
