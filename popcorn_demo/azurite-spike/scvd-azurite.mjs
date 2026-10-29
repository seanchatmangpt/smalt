// W30-S — SCVD second-backend proof: run the storage portion of the SCVD
// contract (container create -> blob PUT byte-equal -> GET -> delete)
// against Azurite (devstoreaccount1) on 127.0.0.1:10100 — the SAME byte-equal
// assertions the smalt blob leg witnessed, different backend.
//
// Result row lands in popcorn_demo/azurite-spike/scvd-azurite.jsonl (spike-local).
// It is NOT appended to docs/jira/v*/bench/scvd.jsonl — that corpus is
// smalt-host-only by definition.
//
// Version note: @azure/storage-blob 12.34 hardcodes x-ms-version 2026-10-06 and
// drops any `version` client option (getCoreClientOptions passes only
// httpClient+factories), so the server runs with --skipApiVersionCheck (same
// as W30-G's dual-mode leg). XMS_VERSION env can force a client pin.
//
// Run: node scvd-azurite.mjs   (exit 0 pass / 1 fail)
"use strict";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { BlobServiceClient, StorageSharedKeyCredential } from "@azure/storage-blob";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ENDPOINT = process.env.AZURITE_BLOB_URL || "http://127.0.0.1:10100/devstoreaccount1";
const ACCOUNT = "devstoreaccount1";
const KEY =
  "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";
const API_VERSION = process.env.XMS_VERSION || undefined;

let pass = 0, fail = 0;
const fails = [];
function record(name, err) {
  if (err) { fail++; fails.push(name + ": " + (err.message || err)); console.log("FAIL " + name + ": " + (err.message || err)); }
  else { pass++; console.log("PASS " + name); }
}

async function main() {
  console.log("[scvd-azurite] endpoint=" + ENDPOINT + " x-ms-version=" + API_VERSION);
  const svc = new BlobServiceClient(
    ENDPOINT,
    new StorageSharedKeyCredential(ACCOUNT, KEY),
    API_VERSION ? { version: API_VERSION } : undefined
  );
  const suffix = Date.now() + "-" + crypto.randomBytes(3).toString("hex");
  const containerName = "w30s-container-" + suffix;
  const blobName = "w30s-blob-" + suffix + ".txt";
  const payload = Buffer.from("w30s-scvd-bytes-" + suffix, "utf8");

  // 1. container create
  const container = svc.getContainerClient(containerName);
  try {
    const r = await container.create();
    record("scvd.container-create.201", r._response.status !== 201 ? new Error("status " + r._response.status) : null);
  } catch (e) { record("scvd.container-create.201", e); }

  // 2. blob PUT
  const blob = container.getBlockBlobClient(blobName);
  try {
    const r = await blob.upload(payload, payload.length);
    record("scvd.blob-put.201", r._response.status !== 201 ? new Error("status " + r._response.status) : null);
  } catch (e) { record("scvd.blob-put.201", e); }

  // 3. GET byte-equal
  try {
    const buf = await blob.downloadToBuffer();
    const equal = Buffer.compare(buf, payload) === 0;
    record("scvd.blob-get.byte-equal", equal ? null : new Error("bytes differ: got " + buf.length + "B, sent " + payload.length + "B"));
  } catch (e) { record("scvd.blob-get.byte-equal", e); }

  // 4. delete blob + container (cleanup is part of the contract)
  try {
    const r = await blob.delete();
    record("scvd.blob-delete.202", ![202, 204].includes(r._response.status) ? new Error("status " + r._response.status) : null);
  } catch (e) { record("scvd.blob-delete.202", e); }
  try {
    await container.delete();
    record("scvd.container-delete", null);
  } catch (e) { record("scvd.container-delete", e); }

  const standing = fail === 0 && pass >= 4 ? "PASS" : "FAIL";
  const row = {
    lane: "w30-s",
    surface: "scvd-storage",
    backend: "azurite",
    endpoint: ENDPOINT,
    op: "container-create:blob-put:blob-get-byte-equal:blob-delete:container-delete",
    pass, fail,
    standing,
    errors: fails,
    api_version_pinned: API_VERSION,
    machine: process.platform + " " + process.arch,
    at: new Date().toISOString(),
  };
  const out = path.join(__dirname, "scvd-azurite.jsonl");
  fs.appendFileSync(out, JSON.stringify(row) + "\n");
  console.log("[scvd-azurite] standing=" + standing + " row-> " + out);
  process.exit(standing === "PASS" ? 0 : 1);
}

main().catch((e) => { console.error("FATAL " + (e.message || e)); process.exit(1); });
