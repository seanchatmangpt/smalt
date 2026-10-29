// KD-114 witness probe (S17-A, falsifier lane) — real-SDK blob round trip
// under enforce auth over the TLS twin (https://127.0.0.1:9444).
//
// Close condition (KNOWN_DIVERGENCES.md KD-114): official @azure/storage-blob
// BlobClient upload -> list -> download byte-equal under enforce auth.
// Auth channel: emulator STS bearer (the channel the twin admits; the
// enforce-mode bearer plug refuses SharedKey per KD-114's original FAIL row,
// and lib/smalt has no SharedKey admit path — noted in the receipt).
// TLS CA trust via NODE_EXTRA_CA_CERTS (.smalt/tls CA).
//
// Run: NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node verification/ts/kd114.probe.cjs
"use strict";
const path = require("node:path");
const fs = require("node:fs");
const REPO = process.env.SMALT_REPO || path.resolve(__dirname, "../..");
const azblob = require(path.join(REPO, "verification/ts/node_modules/@azure/storage-blob"));
const {
  BlobServiceClient,
  BlobClient,
  StorageSharedKeyCredential,
  generateBlobSASQueryParameters,
  BlobSASPermissions,
} = azblob;

const TLS_URL = "https://127.0.0.1:9444";
const ACCOUNT = "popcorn";
const TENANT = "organizations";
const KEY = process.env.SMALT_SB_SHARED_KEY || "ws8sharedkey";

let pass = 0, fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + (err.message || err)); }
  else { pass++; console.log("PASS " + name); }
}
// synchronous trace to stderr (survives process.exit; console.log to a pipe is async)
function trace(m) { fs.writeSync(2, "[step] " + m + "\n"); }

// Emulator STS: any client_id/secret accepted; returns HS256 access_token.
async function fetchBearer() {
  const res = await fetch(`${TLS_URL}/${TENANT}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: "kd114-probe", client_secret: "kd114-secret" }),
  });
  if (!res.ok) throw new Error(`STS ${res.status}`);
  const body = await res.json();
  if (!body.access_token) throw new Error("STS returned no access_token");
  return body.access_token;
}

// Minimal TokenCredential over the emulator STS (real credential object, real
// transport — no mock; the SDK pipeline calls getToken on every 401-challenge).
class StsTokenCredential {
  async getToken() {
    return { token: await fetchBearer(), expiresOnTimestamp: Date.now() + 3600_000 };
  }
}

async function main() {
  const bearer = new BlobServiceClient(
    `${TLS_URL}/${ACCOUNT}`,
    new StsTokenCredential()
  );

  const containerName = "kd114-container-" + Date.now(); // unique per run: the emulator answers 200 (not 409) on create-existing, which breaks createIfNotExists
  const blobName = "kd114-blob-" + Date.now() + "txt";
  const payload = Buffer.from("kd114-bytes-" + Date.now(), "utf8");

  // ---- 1. Bearer (STS): upload -> list -> download byte-equal -----------------
  const containerClient = bearer.getContainerClient(containerName);
  trace("create");
  await containerClient.create(); // unique name, expect 201

  const blockBlob = containerClient.getBlockBlobClient(blobName);
  trace("upload");
  await blockBlob.upload(payload, payload.length);
  console.log("uploaded " + blobName + " (" + payload.length + " bytes)");

  trace("list");
  const listed = [];
  for await (const item of containerClient.listBlobsFlat()) {
    listed.push(item.name);
  }
  record("bearer.list.includes-blob", listed.includes(blobName) ? undefined : new Error("not listed"));

  trace("download");
  const downloaded = await containerClient.getBlobClient(blobName).downloadToBuffer();
  record(
    "bearer.download.byte-equal",
    Buffer.compare(payload, downloaded) === 0
      ? undefined
      : new Error(`byte mismatch up=${payload.length} down=${downloaded.length}`)
  );

  // ---- 2. SharedKey leg (typed note if refused) -------------------------------
  trace("sharedkey-leg");
  try {
    const sk = new BlobServiceClient(
      `${TLS_URL}/${ACCOUNT}`,
      new StorageSharedKeyCredential(ACCOUNT, KEY)
    );
    await sk.getContainerClient(containerName).getProperties();
    console.log("NOTE sharedkey leg: ADMITTED (unexpected per lib survey)");
  } catch (e) {
    console.log("NOTE sharedkey leg refused (typed): " + (e.message || e) + " statusCode=" + e.statusCode);
  }

  // ---- 3. SAS leg (typed note if refused) -------------------------------------
  trace("sas-leg");
  try {
    const startsOn = new Date(Date.now() - 60_000);
    const expiresOn = new Date(Date.now() + 600_000);
    const sas = generateBlobSASQueryParameters(
      { containerName, blobName, permissions: BlobSASPermissions.parse("r"), expiresOn, startsOn },
      new StorageSharedKeyCredential(ACCOUNT, KEY)
    ).toString();
    const sasUrl = bearer.getContainerClient(containerName).getBlobClient(blobName).url + "?" + sas;
    const sasBlob = new BlobClient(sasUrl);
    const sasDown = await sasBlob.downloadToBuffer();
    console.log("NOTE sas leg: download " + (Buffer.compare(payload, sasDown) === 0 ? "BYTE-EQUAL" : "MISMATCH"));
  } catch (e) {
    console.log("NOTE sas leg refused (typed): " + (e.message || e) + " statusCode=" + e.statusCode);
  }

  console.log(`SUMMARY pass=${pass} fail=${fail}`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  trace("FATAL " + (e.message || e) + " statusCode=" + e.statusCode);
  try { trace("fatal-resp " + JSON.stringify({status: e.response.status, hdrs: Object.fromEntries(e.response.headers.entries())})); } catch {}
  try { trace("fatal-stack " + (e.stack || "").split("\n").slice(1, 6).join(" | ")); } catch {}
  process.exit(1);
});
