// W30-G — testing-9 dual-mode witness: ONE suite, UNCHANGED assertions, two backends.
// BACKEND=smalt   -> smalt TLS twin https://127.0.0.1:9444, SharedKey per kd114-sharedkey.probe.cjs
//                    (account "popcorn", key base64(sha256(account+"smalt-dev-sb")))
// BACKEND=azurite -> local azurite blob endpoint (devstoreaccount1, well-known dev key)
//
// Full blob round trip, identical assertions either way:
//   container create -> PUT -> list -> GET byte-equal -> delete
//
// Run:
//   cd popcorn_demo/azurite-spike
//   NODE_EXTRA_CA_CERTS=../../.smalt/tls/ca-cert.pem BACKEND=smalt   node dual-mode-test.mjs
//   BACKEND=azurite node dual-mode-test.mjs   (azurite listening on 127.0.0.1:10000)
"use strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import crypto from "node:crypto";
import { BlobServiceClient, StorageSharedKeyCredential } from "@azure/storage-blob";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BACKEND = process.env.BACKEND || "smalt";

let base, account, credential;
if (BACKEND === "smalt") {
  base = "https://127.0.0.1:9444";
  account = "popcorn";
  const KEY =
    process.env.SMALT_SB_SHARED_KEY ||
    crypto.createHash("sha256").update(account + "smalt-dev-sb").digest("base64");
  credential = new StorageSharedKeyCredential(account, KEY);
} else if (BACKEND == "azurite") {
  base = process.env.AZURITE_BLOB_URL || "http://127.0.0.1:10000";
  account = "devstoreaccount1";
  const KEY =
    "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";
  credential = new StorageSharedKeyCredential(account, KEY);
} else {
  console.error("BACKEND must be smalt|azurite, got: " + BACKEND);
  process.exit(2);
}

let pass = 0, fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + (err.message || err)); }
  else { pass++; console.log("PASS " + name); }
}

async function main() {
  console.log("[backend] " + BACKEND + " endpoint=" + base + "/" + account);
  const svc = new BlobServiceClient(base + "/" + account, credential);

  const containerName = "w30g-container-" + Date.now();
  const blobName = "w30g-blob-" + Date.now() + ".txt";
  const payload = Buffer.from("w30g-bytes-" + Date.now(), "utf8");

  // 1. container create
  const container = svc.getContainerClient(containerName);
  const createResp = await container.create();
  record(
    "dual.container-create.201",
    createResp._response.status !== 201 && createResp._response.status !== 201
      ? new Error("status " + createResp._response.status)
      : undefined
  );

  // 2. PUT
  const blockBlob = container.getBlockBlobClient(blobName);
  const upResp = await blockBlob.upload(payload, payload.length, {
    metadata: { w30g: "dual-mode" },
  });
  record(
    "dual.put.2xx",
    upResp._response.status >= 300 ? new Error("status " + upResp._response.status) : undefined
  );

  // 3. list
  const listed = [];
  for await (const item of container.listBlobsFlat()) listed.push(item.name);
  record(
    "dual.list.includes-blob",
    listed.includes(blobName) ? undefined : new Error("blob not in listing")
  );

  // 4. GET byte-equal
  const downloaded = await container.getBlobClient(blobName).downloadToBuffer();
  record(
    "dual.get.byte-equal",
    Buffer.compare(payload, downloaded) === 0
      ? undefined
      : new Error("byte mismatch up=" + payload.length + " down=" + downloaded.length)
  );

  // 5. delete
  const delResp = await blockBlob.delete();
  record(
    "dual.delete.2xx",
    delResp._response.status >= 300 ? new Error("status " + delResp._response.status) : undefined
  );

  await container.delete();

  console.log("SUMMARY backend=" + BACKEND + " pass=" + pass + " fail=" + fail);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.log("FATAL backend=" + BACKEND + " " + (e.message || e) + " statusCode=" + (e.statusCode || "n/a"));
  process.exit(1);
});
