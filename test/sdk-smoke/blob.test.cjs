"use strict";
// T3 blob.test.cjs — @azure/storage-blob against the egress blob plane (8443).
// Zero installs: vendored SDK via SMALT_SDK_ROOT.
//
// Auth wiring (honest, documented): this test runs against the SDK-tier
// substrate booted by run.mjs in auth_mode :anonymous (config/test.exs).
// The JS SDK cannot inject the smalt STS Bearer on a plain-HTTP endpoint
// (storage OAuth requires https; dual SharedKey+Bearer is not a supported
// SDK mode), so the enforce-mode Bearer contract is NOT exercised here —
// it is covered by test/auth_enforce_test.exs and the arm.test.cjs rows
// against the enforce-mode twin (9444). SharedKeyCredential signing is
// kept so the wire exercises real request signing.
const assert = require("node:assert/strict");
const { test } = require("node:test");
const path = require("node:path");

const SDK_ROOT =
  process.env.SMALT_SDK_ROOT || (function(){ console.error("[sdk-smoke] set SMALT_SDK_ROOT to a node_modules dir containing @azure packages"); process.exit(3); })();
const { BlobServiceClient, StorageSharedKeyCredential } = require(
  path.join(SDK_ROOT, "@azure/storage-blob"),
);

const BASE = "http://127.0.0.1:8443";
const ACCOUNT = "smaltacct";
const KEY = "smaltacct-key";

function client() {
  return new BlobServiceClient(
    `${BASE}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, KEY),
  );
}

test("blob: create container, upload multibyte, download equal, delete 202", async () => {
  const service = client();
  const container = service.getContainerClient(`smoke-${Date.now()}`);
  // Egress default is immutable (WORM); opt THIS container out via the
  // substrate's x-ms-immutable-policy contract so delete can succeed. The
  // JS SDK does not expose this substrate extension header on create, so
  // the create is raw (anonymous-mode substrate; the SDK carries the real
  // SharedKey signature for the subsequent ops).
  const mk = await fetch(container.url, {
    method: "PUT",
    headers: {
      "x-ms-version": "2021-04-01",
      "x-ms-immutable-policy": "false",
    },
    signal: AbortSignal.timeout(60_000),
  });
  assert.equal(mk.status, 201, `mutable container create 201, got ${mk.status}`);

  const blob = container.getBlockBlobClient("greeting.txt");
  const content = Buffer.from("héllo smalt — multibyte 🌊 content", "utf8");
  const up = await blob.upload(content, content.length, {
    abortSignal: AbortSignal.timeout(60_000),
  });
  assert.equal(up._response.status, 201, "upload 201");

  const dl = await blob.downloadToBuffer(undefined, undefined, {
    abortSignal: AbortSignal.timeout(60_000),
  });
  assert.ok(dl.equals(content), "downloaded bytes equal uploaded bytes");

  const del = await blob.deleteIfExists({
    abortSignal: AbortSignal.timeout(60_000),
  });
  assert.equal(del._response.status, 202, "delete 202");
});

test("blob: immutable container rejects overwrite with 409", async () => {
  const service = client();
  const container = service.getContainerClient(`smoke-imm-${Date.now()}`);
  // Egress default (no x-ms-immutable-policy: false) is immutable.
  await container.create({ abortSignal: AbortSignal.timeout(60_000) });

  const blob = container.getBlockBlobClient("locked.bin");
  const first = await blob.upload(Buffer.from("first"), 5, {
    abortSignal: AbortSignal.timeout(60_000),
  });
  assert.equal(first._response.status, 201, "first upload 201");

  await assert.rejects(
    blob.upload(Buffer.from("second"), 6, {
      abortSignal: AbortSignal.timeout(60_000),
    }),
    (err) => {
      assert.equal(err.statusCode, 409, `expected 409, got ${err.statusCode}`);
      return true;
    },
    "immutable overwrite must 409",
  );
});
