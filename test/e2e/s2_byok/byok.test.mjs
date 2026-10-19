// test/e2e/s2_byok/byok.test.mjs
// S2 Bring-Your-Own-Key custody chain e2e, run against a live smalt substrate
// (egress router on http://127.0.0.1:8443, booted by run.sh with the MAA
// measurement baseline registered).
//
// Custody chain:
//   (1) substrate boot w/ attestation baseline (hex64 measurement registered)
//   (2) create CMK w/ release policy (required claim attest) via raw REST
//   (3) negative: non-baseline measurement -> 400
//   (4) SKR release: negatives (no token 403 / garbage token 403 / no policy
//       400 KeyNotExportable) and positive (attest -> Bearer MAA token ->
//       released key material)
//   (5) custody use: AES-GCM envelope over blob content — vault-held data key
//       encrypt/decrypt via smalt KeyVaultActions (raw REST), outer wrap under
//       a custody key derived from the released key material, upload via
//       vendored @azure/storage-blob, read back, unwrap, decrypt, assert equal
//   (6) cleanup
//
// Exit codes: 0 all steps pass; nonzero = failing step (node --test lists the
// failing step by name; run.sh maps harness classes to 2/3).

import { test } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../../..");
const require_ = createRequire(import.meta.url);

const SDK_ROOT =
  process.env.SMALT_SDK_ROOT || path.join(REPO, "test/sdk-full/node_modules");
const { BlobServiceClient, StorageSharedKeyCredential } = require_(
  path.join(SDK_ROOT, "@azure/storage-blob"),
);

const BASE = process.env.SMALT_EGRESS_BASE || "http://127.0.0.1:8443";
const ARM_BASE = process.env.SMALT_ARM_BASE || "http://127.0.0.1:9443";
const ACCOUNT = "smaltacct";
const KEY = "smaltacct-key";

// 64-hex-char measurement registered in the baseline at boot (run.sh -e eval).
const MEASUREMENT = process.env.SMALT_BYOK_MEASUREMENT || "ab".repeat(32);
const NON_BASELINE = "cd".repeat(32); // hex64, not registered

const CMK = `custody-cmk-${Date.now()}`;
const STATIC_KEY = `custody-static-${Date.now()}`; // no release policy
const ENVELOPE_KEY = `custody-envelope-${Date.now()}`; // oct-HSM data key
const CONTAINER = `byok-${Date.now()}`;
const BLOB = "custody-envelope.bin";

// State handed forward across steps.
const state = { token: null, released: null };

function log(msg) {
  console.log(`[byok] ${msg}`);
}

async function rest(method, pathname, { headers = {}, body } = {}) {
  const res = await fetch(`${BASE}${pathname}`, {
    method,
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  return { status: res.status, json, text };
}

// ---------------------------------------------------------------------------
// KD-15 challenge handshake (corpus premise pin, r239/r240): KV corpus clients
// send the first request TOKENLESS and only attach a bearer after the 401 +
// WWW-Authenticate challenge. On the challenge we mint an STS bearer from the
// ARM authority the challenge itself names, then resend. (The legacy-SKR
// fallthrough — x-ms-compliance-status raw header — is used by STEP 4a, whose
// contract IS the fallthrough verdict.)
// ---------------------------------------------------------------------------

let cachedBearer = null;

async function mintBearer() {
  const res = await fetch(`${ARM_BASE}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "s2-byok",
      client_secret: "dev",
    }),
    signal: AbortSignal.timeout(30_000),
  });
  const body = await res.text();
  assert.equal(res.status, 200, `STS mint failed ${res.status}: ${body}`);
  const token = JSON.parse(body).access_token;
  assert.ok(token, "STS mint returned access_token");
  return token;
}

async function kvRest(method, pathname, opts = {}) {
  let res = await rest(method, pathname, opts);
  const challenged =
    res.status === 401 &&
    res.json?.error?.code === "AuthenticationFailed" &&
    (res.text.toLowerCase().includes("www-authenticate") ||
      res.json?.error?.message === "MissingBearerToken");
  if (challenged) {
    cachedBearer ??= await mintBearer();
    res = await rest(method, pathname, {
      ...opts,
      headers: { ...opts.headers, authorization: `Bearer ${cachedBearer}` },
    });
  }
  return res;
}

function blobClient() {
  return new BlobServiceClient(
    `${BASE}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, KEY),
  );
}

// ---------------------------------------------------------------------------
// Step 1 — substrate boot with attestation baseline registered
// ---------------------------------------------------------------------------

test("STEP 1 substrate boot: baseline measurement attests (sevsnpvm)", async () => {
  const { status, json } = await rest("POST", "/attest/sevsnpvm", {
    body: { measurement: MEASUREMENT },
  });
  assert.equal(status, 200, `attest baseline -> 200, got ${status}: ${JSON.stringify(json)}`);
  assert.ok(json?.token, "attestation token present");
  assert.equal(json?.claims?.["x-ms-attestation-type"], "sevsnpvm");
  assert.equal(json?.claims?.["x-ms-compliance-status"], "azure-compliant-cvm");
  log("step 1 PASS: baseline attested, MAA token issued");
});

// ---------------------------------------------------------------------------
// Step 2 — create the CMK with a release policy (required claim: attest)
// ---------------------------------------------------------------------------

test("STEP 2 create CMK: /keys/:name/create with release policy", async () => {
  const { status, json } = await kvRest("POST", `/keys/${CMK}/create`, {
    body: {
      kty: "oct-HSM",
      release_policy: {
        anyOf: [
          {
            authority: "attestation",
            claim: "x-ms-compliance-status",
            equals: "azure-compliant-cvm",
          },
        ],
        allowed_operations: ["release", "encrypt", "decrypt"],
      },
    },
  });
  // NOTE: the create route answers 200 (send_json(conn, 200, ...)), not 201.
  assert.equal(status, 200, `create -> 200, got ${status}: ${JSON.stringify(json)}`);
  assert.equal(json?.attributes?.exportable, true, "policy makes key exportable");
  assert.ok(json?.key?.kid, "kid present");
  assert.equal(json?.release_policy?.anyOf?.[0]?.claim, "x-ms-compliance-status");
  log("step 2 PASS: CMK created with attest release policy");
});

// ---------------------------------------------------------------------------
// Step 3 — negative: attest with a non-baseline measurement
// ---------------------------------------------------------------------------

test("STEP 3 negative: non-baseline measurement -> 400 attestationFailedVerdict", async () => {
  const { status, json } = await rest("POST", "/attest/sevsnpvm", {
    body: { measurement: NON_BASELINE },
  });
  assert.equal(status, 400, `expected 400, got ${status}: ${JSON.stringify(json)}`);
  assert.equal(json?.error?.code, "attestationFailedVerdict");
  log("step 3 PASS: out-of-baseline measurement refused 400");
});

// ---------------------------------------------------------------------------
// Step 4 — SKR release: negatives then positive
// ---------------------------------------------------------------------------

test("STEP 4a negative: release WITHOUT token -> 403 UnauthorizedAttestation", async () => {
  const { status, json } = await kvRest("POST", `/keys/${CMK}/release?api-version=7.4`, { body: {} });
  assert.equal(status, 403, `expected 403, got ${status}: ${JSON.stringify(json)}`);
  assert.equal(json?.error?.code, "UnauthorizedAttestation");
  log("step 4a PASS: release without token refused 403");
});

test("STEP 4b negative: release with garbage token -> 403", async () => {
  const { status, json } = await rest("POST", `/keys/${CMK}/release?api-version=7.4`, {
    headers: { authorization: "Bearer not-a-jwt" },
    body: {},
  });
  assert.equal(status, 403, `expected 403, got ${status}: ${JSON.stringify(json)}`);
  assert.equal(json?.error?.code, "UnauthorizedAttestation");
  log("step 4b PASS: garbage token refused 403");
});

test("STEP 4c attest -> SKR release with Bearer MAA token -> released material", async () => {
  const attest = await rest("POST", "/attest/sevsnpvm", {
    body: { measurement: MEASUREMENT },
  });
  assert.equal(attest.status, 200, "attest 200");
  const token = attest.json.token;
  assert.ok(token.split(".").length === 3, "token is a JWT-shaped RS256 token");

  const rel = await rest("POST", `/keys/${CMK}/release?api-version=7.4`, {
    headers: { authorization: `Bearer ${token}` },
    body: {},
  });
  assert.equal(rel.status, 200, `release -> 200, got ${rel.status}: ${JSON.stringify(rel.json)}`);
  assert.equal(rel.json?.status, "Released");
  assert.ok(rel.json?.value, "released key material present");
  assert.ok(String(rel.json?.kid).includes("/keys/"), "kid echoes key");

  // Hand forward for the custody-use step.
  state.token = token;
  state.released = rel.json;
  log("step 4c PASS: SKR release succeeded with attested token");
});

test("STEP 4d negative: release of policy-less key -> 400 KeyNotExportable", async () => {
  const created = await kvRest("POST", `/keys/${STATIC_KEY}/create`, {
    body: { kty: "oct-HSM" },
  });
  assert.equal(created.status, 200, "create static key 200");

  // Valid token: the policy gate (400) must fire before the auth gate.
  const ok = await rest("POST", "/attest/sevsnpvm", {
    body: { measurement: MEASUREMENT },
  });
  assert.equal(ok.status, 200, "attest 200");

  const rel = await rest("POST", `/keys/${STATIC_KEY}/release?api-version=7.4`, {
    headers: { authorization: `Bearer ${ok.json.token}` },
    body: {},
  });
  assert.equal(rel.status, 400, `expected 400 KeyNotExportable, got ${rel.status}: ${JSON.stringify(rel.json)}`);
  assert.equal(rel.json?.error?.code, "KeyNotExportable");
  log("step 4d PASS: policy-less key refused 400 KeyNotExportable");
});

// ---------------------------------------------------------------------------
// Step 5 — custody use: AES-GCM envelope around blob content
// ---------------------------------------------------------------------------

test("STEP 5 custody use: encrypt envelope, upload via Blob SDK, read back, decrypt, assert", async () => {
  assert.ok(state.token && state.released, "release step must have run first");

  // 5.1 Data key: oct-HSM key in the vault; crypto goes through smalt's
  // KeyVaultActions (raw REST), AES-256-GCM.
  const created = await kvRest("POST", `/keys/${ENVELOPE_KEY}/create`, {
    body: {
      kty: "oct-HSM",
      release_policy: {
        anyOf: [{ authority: "attestation", claim: "x-ms-compliance-status", equals: "azure-compliant-cvm" }],
        allowed_operations: ["release", "encrypt", "decrypt"],
      },
    },
  });
  assert.equal(created.status, 200, "create envelope key 200");

  const plaintext = Buffer.from(
    `byok custody payload ${Date.now()} — multibyte 🌊 confidential`,
    "utf8",
  );

  // 5.2 Encrypt blob content client-side via raw REST (A256GCM).
  const enc = await rest("POST", `/keys/${ENVELOPE_KEY}/encrypt`, {
    headers: { authorization: `Bearer ${state.token}` },
    body: { alg: "A256GCM", value: plaintext.toString("base64") },
  });
  assert.equal(enc.status, 200, `encrypt 200, got ${enc.status}: ${JSON.stringify(enc.json)}`);
  assert.ok(enc.json.iv && enc.json.tag, "GCM iv+tag returned");
  const envelope = {
    v: 1,
    alg: "A256GCM",
    kid: enc.json.kid,
    ct: enc.json.value,
    iv: enc.json.iv,
    tag: enc.json.tag,
  };

  // 5.3 Custody key derived from the RELEASED key material (the actual bytes
  // the vault returns for the release) — binds the envelope to the custody
  // chain. 32-byte AES-256 key via SHA-256; never stored anywhere.
  const custodyKey = crypto
    .createHash("sha256")
    .update(`${state.released.value}|${state.released.kid}|${ENVELOPE_KEY}`)
    .digest();

  const iv2 = crypto.randomBytes(12);
  const cipher2 = crypto.createCipheriv("aes-256-gcm", custodyKey, iv2);
  const ct2 = Buffer.concat([cipher2.update(JSON.stringify(envelope)), cipher2.final()]);
  const tag2 = cipher2.getAuthTag();

  // 5.4 Upload outer envelope via vendored @azure/storage-blob.
  const container = blobClient().getContainerClient(CONTAINER);
  await container.create({ abortSignal: AbortSignal.timeout(60_000) });
  const blob = container.getBlockBlobClient(BLOB);
  const payload = JSON.stringify({
    wrapped: true,
    cmk: CMK,
    ct: ct2.toString("base64"),
    iv: iv2.toString("base64"),
    tag: tag2.toString("base64"),
  });
  const up = await blob.upload(Buffer.from(payload), Buffer.byteLength(payload), {
    abortSignal: AbortSignal.timeout(60_000),
  });
  assert.equal(up._response.status, 201, `blob upload 201, got ${up._response.status}`);

  // 5.5 Read back and unwrap with the same derived custody key.
  // Raw REST GET (blob GET carries content-length + etag; read-back needs
  // only x-ms-version on this substrate).
  const dl = await fetch(`${BASE}/${ACCOUNT}/${CONTAINER}/${BLOB}`, {
    headers: { "x-ms-version": "2021-12-02" },
    signal: AbortSignal.timeout(60_000),
  });
  assert.equal(dl.status, 200, `blob read-back 200, got ${dl.status}`);
  const stored = JSON.parse(Buffer.from(await dl.arrayBuffer()).toString("utf8"));
  assert.equal(stored.wrapped, true);
  assert.equal(stored.cmk, CMK);

  const dec2 = crypto.createDecipheriv("aes-256-gcm", custodyKey, Buffer.from(stored.iv, "base64"));
  dec2.setAuthTag(Buffer.from(stored.tag, "base64"));
  const envelopeJson = Buffer.concat([dec2.update(Buffer.from(stored.ct, "base64")), dec2.final()]);

  // 5.6 Inner decrypt via raw REST with the vault-held data key.
  const env = JSON.parse(envelopeJson.toString("utf8"));
  const dec = await rest("POST", `/keys/${ENVELOPE_KEY}/decrypt`, {
    headers: { authorization: `Bearer ${state.token}` },
    body: { alg: "A256GCM", value: env.ct, iv: env.iv, tag: env.tag },
  });
  assert.equal(dec.status, 200, `decrypt 200, got ${dec.status}: ${JSON.stringify(dec.json)}`);
  const recovered = Buffer.from(dec.json.value, "base64");
  assert.ok(recovered.equals(plaintext), "decrypted content equals original");
  log("step 5 PASS: custody envelope round-trip over blob plane, content equal");
});

// ---------------------------------------------------------------------------
// Step 6 — cleanup blob container (best-effort; failures still surface)
// ---------------------------------------------------------------------------

test("STEP 6 cleanup: delete blob, best-effort container delete", async () => {
  const container = blobClient().getContainerClient(CONTAINER);
  const blob = container.getBlockBlobClient(BLOB);
  // Container is WORM-immutable by default: blob delete answers 409
  // ContainerLocked. That refusal is itself custody-correct behavior —
  // best-effort only, accept either delete or the WORM 409.
  try {
    await blob.deleteIfExists({ abortSignal: AbortSignal.timeout(60_000) });
  } catch (err) {
    if (err?.statusCode !== 409) throw err;
    log("blob delete refused (WORM ContainerLocked 409) — left in place");
  }
  // The egress router exposes no DELETE /:account/:container route; skip
  // container deletion when the substrate answers RouteNotFound (404) — or
  // when the WORM-immutable container refuses deletion outright
  // (ContainerLocked 409, custody-correct on this substrate).
  try {
    await container.delete({ abortSignal: AbortSignal.timeout(60_000) });
  } catch (err) {
    if (err?.statusCode !== 404 && err?.statusCode !== 409) throw err;
    log(
      err?.statusCode === 409
        ? "container delete refused (WORM ContainerLocked 409) — left in place"
        : "container delete unsupported (RouteNotFound) — blob deleted only",
    );
  }
  log("step 6 PASS: cleanup done");
});
