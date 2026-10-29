// W30-J2 auth-enforcement divergence court (completes the never-landed W30-J).
//
// Three backends, one probe shape: {valid, none, tampered} auth per backend.
//   backend 1: smalt blob TLS twin https://127.0.0.1:9444, auth_mode :enforce
//              (STS bearer admit + SharedKey admit, typed 401 refusals)
//   backend 2: Azurite blob 127.0.0.1:10000 (PID 58569, --skipApiVersionCheck)
//              — enforces SharedKey against the PUBLIC well-known dev key
//              (tokenless and tampered both 403 AuthorizationFailure; no
//              bearer/STS surface exists)
//   backend 3: Cosmos DB vNext emulator docker w30c-cosmos-vnext
//              (gateway http://127.0.0.1:8081 + probe plane 8080) — NO
//              signature verification: master-key-shaped, garbage-key, and
//              tokenless GET /dbs all 200
//
// Output: one jsonl row per {backend, case, status, typed_verdict} to
// popcorn_demo/azurite-spike/auth-court.jsonl (truncated per run) plus a prose
// table on stdout. The table IS the deliverable: it documents why smalt
// :enforce is the only real auth-testing surface of the three (the other two
// cannot test auth by design — Azurite's gate key is public knowledge, vNext
// verifies nothing). Refusals-by-design count as witnessed.
//
// Chicago discipline: real HTTP over the real wire to real emulators; no mocks.
//
// Run: NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem node \
//   popcorn_demo/azurite-spike/auth-court.mjs
"use strict";

import { writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createRequire } from "node:module";
import crypto from "node:crypto";
import http from "node:http";
import https from "node:https";

const REPO = "/Users/sac/smalt";
const OUT = join(REPO, "popcorn_demo/azurite-spike/auth-court.jsonl");

const SMALT_BLOB = "https://127.0.0.1:9444";
// The STS rides the same TLS twin listener as the blob plane (the 9443
// control-plane TLS resets loopback handshakes when probed outside the app).
const SMALT_STS = "https://127.0.0.1:9444/smalt-emulator-tenant/oauth2/v2.0/token";
const SMALT_ACCOUNT = "popcorn";
// scripts/dev_env.sh derivation: base64(sha256(account + "smalt-dev-sb"))
const SMALT_KEY = crypto
  .createHash("sha256")
  .update(SMALT_ACCOUNT + "smalt-dev-sb")
  .digest("base64");
const AZURITE_URL = "http://127.0.0.1:10000";
const AZURITE_ACCOUNT = "devstoreaccount1";
// Azurite well-known PUBLIC dev key.
const AZURITE_KEY =
  "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";
const VNEXT_GATEWAY = "http://127.0.0.1:8081";
const VNEXT_PROBES = "http://127.0.0.1:8080";

// Real official SDK credential for the SharedKey legs (kd114-sharedkey.probe.cjs
// pattern). Run with NODE_EXTRA_CA_CERTS=<repo>/.smalt/tls/ca-cert.pem so the
// SDK trusts the loopback CA over https.
const require_ = createRequire(import.meta.url);
const { BlobServiceClient, StorageSharedKeyCredential } = require_(
  resolve(REPO, "verification/ts/node_modules/@azure/storage-blob"),
);

const rows = [];
function row(backend, kase, status, typedVerdict, expect, detail) {
  rows.push({ backend, case: kase, status, typed_verdict: typedVerdict, expect, detail });
  console.log(
    `${backend.padEnd(18)} ${kase.padEnd(16)} -> ${String(status).padEnd(4)} ${typedVerdict}`
  );
}

// ---------------------------------------------------------------------------
// real HTTP helper (no dependency)
// ---------------------------------------------------------------------------

function req(url, { method = "GET", headers = {}, body = null } = {}) {
  return new Promise((resolvePromise) => {
    const mod = url.startsWith("https") ? https : http;
    const r = mod.request(url, { method, headers, rejectUnauthorized: false }, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => resolvePromise({ status: res.statusCode, body: data, headers: res.headers }));
    });
    r.on("error", (e) => resolvePromise({ status: 0, body: String(e.message || e), headers: {} }));
    if (body) r.write(body);
    r.end();
  });
}

// ---------------------------------------------------------------------------
// SharedKey signing (real Azure Blob SharedKey, 2021-12-02 wire form)
// ---------------------------------------------------------------------------

function sharedKeyHeaders(method, pathAndQuery, account, keyB64) {
  const now = new Date().toUTCString();
  const stringToSign = [
    method, "", "", "", "", "", "",
    now, "", "", "",
    "",
    `x-ms-date:${now}`,
    "x-ms-version:2021-12-02",
    `/${account}${pathAndQuery}`,
  ].join("\n");
  const sig = crypto
    .createHmac("sha256", Buffer.from(keyB64, "base64"))
    .update(stringToSign, "utf8")
    .digest("base64");
  return {
    Authorization: `SharedKey ${account}:${sig}`,
    "x-ms-date": now,
    "x-ms-version": "2021-12-02",
  };
}

// Cosmos REST master-key Authorization (real scheme:
// verb\ntype\ntarget\ndate\n\n — vNext admits the SHAPE without verifying).
function cosmosMasterAuth(sigKeyBuf, resourceLink = "") {
  const now = new Date().toUTCString();
  const payload = `get\ndatabases\n${resourceLink}\n${now}\n\n`;
  const sig = crypto.createHmac("sha256", sigKeyBuf).update(payload, "utf8").digest("base64");
  return { header: `type=master&ver=1.0&sig=${encodeURIComponent(sig)}`, date: now };
}

// ---------------------------------------------------------------------------
// backend 1: smalt TLS twin, :enforce
// ---------------------------------------------------------------------------

async function probeSmalt() {
  const tag = "smalt-9444-enforce";
  const stamp = Date.now();
  const container = `authcourt${stamp}`;

  // (a) valid: real STS bearer — smalt STS admits any client_id/secret in
  // :enforce, then the bearer must admit a container create on the wire.
  const tokenResp = await req(SMALT_STS, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "smalt-emulator-tenant-client",
      client_secret: "emulator-accepted",
      scope: "https://storage.azure.com/.default",
    }).toString(),
  });
  let bearer = null;
  if (tokenResp.status === 200) {
    try { bearer = JSON.parse(tokenResp.body).access_token; } catch { bearer = null; }
  }
  if (bearer) {
    const r = await req(`${SMALT_BLOB}/${SMALT_ACCOUNT}/${container}?restype=container`, {
      method: "PUT",
      headers: { Authorization: `Bearer ${bearer}`, "x-ms-version": "2021-12-02" },
    });
    row(tag, "valid-bearer", r.status,
      r.status === 201 ? "ADMITTED-BEARER" : `REFUSED-${r.status}`,
      "success", `STS ${tokenResp.status}, container create ${r.status}`);
  } else {
    row(tag, "valid-bearer", tokenResp.status, "STS-FAIL", "success",
      `STS ${tokenResp.status}: ${tokenResp.body.slice(0, 120)}`);
  }

  // (b) valid: real SharedKey signed with the per-account emulator dev key
  {
    const name = `${container}-sk`;
    const svc = new BlobServiceClient(
      `${SMALT_BLOB}/${SMALT_ACCOUNT}`,
      new StorageSharedKeyCredential(SMALT_ACCOUNT, SMALT_KEY)
    );
    try {
      await svc.getContainerClient(name).create();
      row(tag, "valid-sharedkey", 201, "ADMITTED-SHAREDKEY", "success",
        "SDK SharedKey container create 201");
    } catch (e) {
      row(tag, "valid-sharedkey", e.statusCode || 0,
        `REFUSED-${e.statusCode || 0}`, "success",
        `SDK SharedKey create: ${String(e.message).slice(0, 100)}`);
    }
  }

  // (c) none: tokenless create must refuse 401 typed
  {
    const name = `${container}-none`;
    const r = await req(`${SMALT_BLOB}/${name}?restype=container`, {
      method: "PUT",
      headers: { "x-ms-version": "2021-12-02" },
    });
    row(tag, "none", r.status,
      r.status === 401 ? "REFUSED-401-TYPED" : `UNEXPECTED-${r.status}`,
      "refusal", r.body.slice(0, 140));
  }

  // (d) tampered: correct SharedKey wire shape, wrong key material
  {
    const name = `${container}-tampered`;
    const badKey = crypto.createHash("sha256").update("tampered-key").digest("base64");
    const h = sharedKeyHeaders("PUT", `/${name}?restype=container`, SMALT_ACCOUNT, badKey);
    const r = await req(`${SMALT_BLOB}/${name}?restype=container`, { method: "PUT", headers: h });
    row(tag, "tampered", r.status,
      r.status === 401 ? "REFUSED-401-TYPED" : `UNEXPECTED-${r.status}`,
      "refusal", r.body.slice(0, 140));
  }
}

// ---------------------------------------------------------------------------
// backend 2: Azurite blob (default instance, well-known PUBLIC dev key)
// ---------------------------------------------------------------------------

async function probeAzurite() {
  const tag = "azurite-blob";
  const stamp = Date.now();
  const c = `authcourt${stamp}`;

  // (a) valid: SharedKey signed with the well-known dev key must admit.
  {
    const name = `${c}-valid`;
    const svc = new BlobServiceClient(
      `${AZURITE_URL}/${AZURITE_ACCOUNT}`,
      new StorageSharedKeyCredential(AZURITE_ACCOUNT, AZURITE_KEY)
    );
    try {
      await svc.getContainerClient(name).create();
      row(tag, "valid-sharedkey", 201, "ADMITTED-SHAREDKEY-WELLKNOWN-KEY", "success",
        "SDK SharedKey create 201 — gate key is PUBLIC (well-known dev key)");
    } catch (e) {
      row(tag, "valid-sharedkey", e.statusCode || 0,
        `REFUSED-${e.statusCode || 0}`, "success",
        `SDK SharedKey create: ${String(e.message).slice(0, 100)}`);
    }
  }

  // (b) none: tokenless create is refused 403 AuthorizationFailure.
  {
    const name = `${c}-none`;
    const r = await req(`${AZURITE_URL}/${AZURITE_ACCOUNT}/${name}?restype=container`, {
      method: "PUT", headers: { "x-ms-version": "2021-12-02" },
    });
    row(tag, "none", r.status,
      r.status === 403 ? "REFUSED-403-ANON-WRITE" : `UNEXPECTED-${r.status}`,
      "refusal",
      `${(r.body.match(/<Code>([^<]+)/) || [])[1] || r.body.slice(0, 100)} — enforcement exists but the gate key is public`);
  }

  // (c) tampered: valid wire shape, garbage key is refused 403.
  {
    const name = `${c}-tampered`;
    const badKey = crypto.createHash("sha256").update("tampered-key").digest("base64");
    const h = sharedKeyHeaders("PUT", `/${name}?restype=container`, AZURITE_ACCOUNT, badKey);
    const r = await req(`${AZURITE_URL}/${AZURITE_ACCOUNT}/${name}?restype=container`, {
      method: "PUT", headers: h,
    });
    row(tag, "tampered", r.status,
      r.status === 403 ? "REFUSED-403-BAD-SIG" : `UNEXPECTED-${r.status}`,
      "refusal",
      `${(r.body.match(/<Code>([^<]+)/) || [])[1] || r.body.slice(0, 100)} — refuses, but gated on a public key and indistinguishable from the tokenless refusal`);
  }
}

// ---------------------------------------------------------------------------
// backend 3: Cosmos DB vNext emulator (8081 gateway + 8080 probe plane)
// ---------------------------------------------------------------------------

async function probeVnext() {
  const tag = "cosmos-vnext";

  // (a) valid-shape master key (classic emulator's well-known key as honest
  // key material; vNext does not verify, so ANY key behaves identically).
  {
    const { header, date } = cosmosMasterAuth(
      Buffer.from("C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QSU5cQ==", "base64")
    );
    const r = await req(`${VNEXT_GATEWAY}/dbs`, {
      headers: { Authorization: header, "x-ms-date": date, "x-ms-version": "2018-12-31" },
    });
    row(tag, "valid-masterkey", r.status,
      r.status === 200 ? "ADMITTED-MASTERKEY-SHAPE" : `REFUSED-${r.status}`,
      "success", `GET /dbs ${r.status} (gateway 8081)`);
  }

  // (b) none: tokenless GET /dbs is admitted 200 — no enforcement.
  {
    const r = await req(`${VNEXT_GATEWAY}/dbs`);
    row(tag, "none", r.status,
      r.status === 200 ? "ADMITTED-ANON (NO-ENFORCEMENT)" : `REFUSED-${r.status}`,
      "refusal-not-observed", `tokenless GET /dbs ${r.status} on gateway 8081`);
  }

  // (c) tampered: correct shape, wrong key is admitted 200.
  {
    const { header, date } = cosmosMasterAuth(Buffer.from("tampered-key-material", "utf8"));
    const r = await req(`${VNEXT_GATEWAY}/dbs`, {
      headers: { Authorization: header, "x-ms-date": date, "x-ms-version": "2018-12-31" },
    });
    row(tag, "tampered", r.status,
      r.status === 200 ? "ADMITTED-BAD-SIG (NO-ENFORCEMENT)" : `REFUSED-${r.status}`,
      "refusal-not-observed",
      `GET /dbs ${r.status} with garbage-key signature — no signature verification exists`);
  }

  // (d) probe plane 8080: /alive /ready /status tokenless 200; no auth surface
  // at all (any other path -> typed 404 with available_endpoints).
  {
    const r = await req(`${VNEXT_PROBES}/alive`);
    row(tag, "probe-plane-anon", r.status,
      r.status === 200 ? "ADMITTED-ANON (NO-AUTH-SURFACE)" : `UNEXPECTED-${r.status}`,
      "refusal-not-observed",
      `tokenless GET /alive ${r.status} on 8080 — probe plane has no auth surface by design`);
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

await probeSmalt();
await probeAzurite();
await probeVnext();

writeFileSync(OUT, rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
console.log(`\nWROTE ${rows.length} rows -> ${OUT}`);
