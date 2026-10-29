// KD-114 close probe (W20-B) — real official @azure/storage-blob SharedKey
// round trip under enforce auth over the TLS twin (https://127.0.0.1:9444).
//
// KD-114 close condition, SharedKey leg: official SDK BlobClient
// upload -> list -> download byte-equal with StorageSharedKeyCredential —
// the channel the emulator refused 401 MalformedBearerHeader before the
// SharedKey admit path landed (lib/smalt/auth/shared_key.ex).
//
// Key: the emulator's per-account dev key, base64(sha256(account+"smalt-dev-sb"))
// (scripts/dev_env.sh derivation; override with SMALT_SB_SHARED_KEY).
//
// Run: NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node verification/ts/kd114-sharedkey.probe.cjs
"use strict";
const path = require("node:path");
const fs = require("node:fs");
const crypto = require("node:crypto");
const REPO = process.env.SMALT_REPO || path.resolve(__dirname, "../..");
const azblob = require(path.join(REPO, "verification/ts/node_modules/@azure/storage-blob"));
const { BlobServiceClient, StorageSharedKeyCredential } = azblob;

const TLS_URL = "https://127.0.0.1:9444";
const ACCOUNT = "popcorn";
const KEY =
  process.env.SMALT_SB_SHARED_KEY ||
  crypto.createHash("sha256").update(ACCOUNT + "smalt-dev-sb").digest("base64");

let pass = 0, fail = 0;
function record(name, err) {
  if (err) { fail++; console.log("FAIL " + name + ": " + (err.message || err)); }
  else { pass++; console.log("PASS " + name); }
}
function trace(m) { fs.writeSync(2, "[step] " + m + "\n"); }

async function main() {
  trace("sharedkey-service-client");
  const sk = new BlobServiceClient(
    TLS_URL + "/" + ACCOUNT,
    new StorageSharedKeyCredential(ACCOUNT, KEY)
  );

  const containerName = "kd114sk-container-" + Date.now();
  const blobName = "kd114sk-blob-" + Date.now() + ".txt";
  const payload = Buffer.from("kd114sk-bytes-" + Date.now(), "utf8");

  trace("create-container");
  const container = sk.getContainerClient(containerName);
  const createResp = await container.create();
  record("sharedkey.create-container.201", createResp.errorCode && new Error("errorCode set"));

  trace("upload");
  const blockBlob = container.getBlockBlobClient(blobName);
  const upResp = await blockBlob.upload(payload, payload.length, {
    metadata: { kd114: "sharedkey-close" },
  });
  record("sharedkey.put.2xx", upResp._response.status >= 300 ? new Error("status " + upResp._response.status) : undefined);

  trace("list");
  const listed = [];
  for await (const item of container.listBlobsFlat()) listed.push(item.name);
  record("sharedkey.list.includes-blob", listed.includes(blobName) ? undefined : new Error("not listed"));

  trace("download");
  const downloaded = await container.getBlobClient(blobName).downloadToBuffer();
  record(
    "sharedkey.download.byte-equal",
    Buffer.compare(payload, downloaded) === 0
      ? undefined
      : new Error("byte mismatch up=" + payload.length + " down=" + downloaded.length)
  );

  trace("get-properties");
  const props = await container.getProperties();
  record("sharedkey.get-properties.2xx", props._response.status >= 300 ? new Error("status " + props._response.status) : undefined);

  // Negative leg: tampered signature must refuse 401 typed (real transport).
  trace("tampered-leg");
  // Tamper leg: the same request shape signed with a WRONG account key — a
  // genuinely bad signature on the wire, produced by the real SDK credential
  // (no monkey-patching: the SDK v12 policy does not route through an
  // instance-overridable hook, and a flipped-padding char is a no-op class).
  const WRONG_KEY = crypto.createHash("sha256").update("not-the-key").digest("base64");
  const badClient = new BlobServiceClient(
    TLS_URL + "/" + ACCOUNT,
    new StorageSharedKeyCredential(ACCOUNT, WRONG_KEY)
  );
  try {
    await badClient.getContainerClient(containerName).getProperties();
    record("sharedkey.tampered-refused.401", new Error("bad signature was ADMITTED"));
  } catch (e) {
    record(
      "sharedkey.tampered-refused.401",
      e.statusCode === 401 ? undefined : new Error("expected 401, got " + e.statusCode + " " + e.message)
    );
  }

  console.log("SUMMARY pass=" + pass + " fail=" + fail);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  trace("FATAL " + (e.message || e) + " statusCode=" + (e.statusCode || "n/a"));
  try {
    trace("fatal-resp " + JSON.stringify({ status: e.response.status }));
  } catch {}
  process.exit(1);
});
