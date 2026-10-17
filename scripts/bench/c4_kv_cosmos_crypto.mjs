// C-4 lane: Key Vault envelope-encryption -> Cosmos cross-product bench.
// The Always Encrypted / field-level crypto pattern: per-doc DEK wrapped by a
// KV KEK (RSA-OAEP-256), fields encrypted locally with AES-256-GCM under the
// DEK, wrapped DEK + ciphertexts stored in Cosmos.
//
// Phases:
//   1. CRYPTO FLOOR  — KV encrypt / decrypt ops/s isolated (100 ops each).
//   2. ENVELOPE WRITE — 200 docs x 3 encrypted fields, DEK-per-doc wrapped via
//      KV encrypt -> cosmos create; docs/s + plaintext create baseline.
//   3. ENVELOPE READ  — read + KV decrypt + local AES-GCM decrypt x3; docs/s
//      vs plaintext read baseline (B-3 witnessed 4405/s on shared substrate).
//   4. KEY REUSE      — wrapped DEK cached (wrap once), fields encrypted /
//      decrypted locally; docs/s delta vs phases 2/3 (the Azure-documented
//      local-DEK optimization).
//
// Self-booted private substrate (scripts/bench/lib.sh bench_boot c4):
//   lane c4 -> ports 39240..39245; ARM 39240, cosmos data 39241, vault TLS 39244.
// Run:
//   cd scripts/bench && source lib.sh && pid=$(bench_boot c4) && \
//   node c4_kv_cosmos_crypto.mjs; rc=$?; bench_down $pid; exit $rc
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SDK_DIR = path.join(ROOT, "test/sdk-full");
const ARM = process.env.C4_ARM ?? "http://127.0.0.1:39240";
const COSMOS = process.env.C4_COSMOS ?? "http://127.0.0.1:39241";
const VAULT = process.env.C4_VAULT ?? "https://127.0.0.1:39244";
const OUT = process.env.C4_OUT ?? path.join(ROOT, "docs/jira/v26.10.14/bench/c4-kv-cosmos.jsonl");

const { KeyClient, CryptographyClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/keyvault-keys/dist/esm/index.js")
);
const { CosmosClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/cosmos/dist/esm/index.js")
);

const N_FLOOR = 100;    // phase 1: measured ops per direction
const N_DOCS = 200;     // phases 2-4: docs per phase
const WARM = 20;        // warmup ops per phase (excluded)
const DEK_BYTES = 32;

const log = (...a) => console.log(new Date().toISOString(), ...a);

// ---- JSONL emission (same schema as lib.sh bench_emit) ----
const MACHINE = JSON.parse(
  execSync(
    `source ${path.join(ROOT, "scripts/bench/lib.sh")} && bench_machine_spec`,
    { shell: "/bin/bash", encoding: "utf8" },
  ).trim(),
);
const LANE = "c4";
function emit(surface, op, n, opsPerSec, p50, p95, p99, errors, extra = {}) {
  const row = {
    lane: LANE, surface, op, n,
    ops_per_sec: +Number(opsPerSec).toFixed(2),
    p50_ms: p50, p95_ms: p95, p99_ms: p99, errors,
    machine: MACHINE, ...extra,
  };
  fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
  log(`SUMMARY ${surface}/${op} n=${n} ${row.ops_per_sec} ops/s p50=${p50} p95=${p95} p99=${p99} err=${errors}`);
}

// Same interpolation as scripts/bench/lib.sh bench_percentile.
function pct(v, p) {
  const s = [...v].sort((a, b) => a - b);
  return s[Math.round((p / 100.0) * (s.length - 1))];
}
function summarize(lats) {
  return {
    p50: +pct(lats, 50).toFixed(3),
    p95: +pct(lats, 95).toFixed(3),
    p99: +pct(lats, 99).toFixed(3),
  };
}

// ---- auth: bearer from the substrate's own ARM STS + force-bearer policy ----
async function mintBearer() {
  const res = await fetch(`${ARM}/oauth2/v2.0/token`, {
    method: "POST",
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "bench-c4",
      client_secret: "dev",
    }),
  });
  if (!res.ok) throw new Error(`STS mint failed ${res.status}: ${await res.text()}`);
  return (await res.json()).access_token;
}
class StsCredential {
  constructor(token) { this.token = token; }
  async getToken() { return { token: this.token, expiresOnTimestamp: Date.now() + 3600_000 }; }
}
// Substrate never issues the 401 WWW-Authenticate challenge, so the SDK's
// challenge-based auth never attaches the token (witnessed in
// keyvault.probe.mjs) — force it in the Sign phase, same as the probe.
function addForceBearer(clientLike, token) {
  const pipeline = clientLike.client?.pipeline;
  if (!pipeline) throw new Error("no pipeline exposed on SDK client");
  pipeline.addPolicy(
    {
      name: "force-bearer",
      sendRequest(req, next) {
        req.headers.set("authorization", `Bearer ${token}`);
        return next(req);
      },
    },
    { phase: "Sign" },
  );
}

// ---- local AES-256-GCM field crypto (the envelope inner layer) ----
function aesEncrypt(dek, plaintext) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", dek, nonce);
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([nonce, ct, cipher.getAuthTag()]);
}
function aesDecrypt(dek, blob) {
  const nonce = blob.subarray(0, 12);
  const tag = blob.subarray(blob.length - 16);
  const ct = blob.subarray(12, blob.length - 16);
  const d = crypto.createDecipheriv("aes-256-gcm", dek, nonce);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]);
}

let errorCount = 0;
const errorLog = [];
function noteErr(op, e) {
  errorCount++;
  errorLog.push({ op, code: e?.code, msg: String(e?.message ?? "").slice(0, 150) });
}

// ===========================================================================
// main
// ===========================================================================
const bearer = await mintBearer();
log("bearer minted, len=" + bearer.length);

const keyClient = new KeyClient(VAULT, new StsCredential(bearer), {
  allowInsecureConnection: true,
  retryOptions: { maxRetries: 0 },
  disableChallengeResourceVerification: true,
});
addForceBearer(keyClient, bearer);

// KEK: real SDK createKey first; substrate-native create route as fallback
// (both routes witnessed in keyvault.probe.mjs).
const KEK_NAME = `c4-kek-${Date.now()}`;
let kekKid;
try {
  const created = await keyClient.createKey(KEK_NAME, "RSA");
  kekKid = `${VAULT}/keys/${KEK_NAME}`;
  log("KEK created via SDK createKey");
} catch (e) {
  const res = await fetch(`${VAULT}/keys/${KEK_NAME}/create?api-version=7.4`, {
    method: "POST",
    headers: { authorization: `Bearer ${bearer}`, "content-type": "application/json" },
    body: JSON.stringify({ kty: "RSA" }),
  });
  if (!res.ok) throw new Error(`KEK create failed ${res.status}: ${await res.text()}`);
  kekKid = `${VAULT}/keys/${KEK_NAME}`;
  log("KEK created via substrate route");
}
// The substrate's kid advertises the canonical front door; rewrite to this
// lane's private vault port so the crypto ops hit the lane-local substrate.
log("KEK kid (lane-local)", kekKid);

// The substrate issues an enriched 401 challenge (resource=127.0.0.1) that the
// real SDK accepts once challenge-resource verification is disabled — the same
// handshake keyvault.probe.mjs witnesses. Challenge policy then attaches the
// bearer from the credential; no injected header needed.
const cryptoClient = new CryptographyClient(kekKid, new StsCredential(bearer), {
  allowInsecureConnection: true,
  retryOptions: { maxRetries: 0 },
  disableChallengeResourceVerification: true,
});

// smoke: one real round-trip before any phase is measured
const smokePt = crypto.randomBytes(DEK_BYTES);
const smokeCt = (await cryptoClient.encrypt({ algorithm: "RSA-OAEP-256", plaintext: smokePt })).result;
const smokeBack = (await cryptoClient.decrypt({ algorithm: "RSA-OAEP-256", ciphertext: smokeCt })).result;
if (Buffer.compare(smokeBack, smokePt) !== 0) throw new Error("KV RSA-OAEP-256 round-trip MISMATCH");
const aesBack = aesDecrypt(smokePt, aesEncrypt(smokePt, Buffer.from("smoke")));
if (aesBack.toString() !== "smoke") throw new Error("AES-GCM round-trip MISMATCH");
log("crypto smoke OK: KV RSA-OAEP-256 + local AES-256-GCM round-trips verified");

// ---- cosmos setup ----
const MASTER_KEY = crypto.randomBytes(32).toString("hex");
const cosmos = new CosmosClient({
  endpoint: COSMOS,
  key: MASTER_KEY,
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});
const DB = `c4db-${Date.now()}`;
const { database } = await cosmos.databases.createIfNotExists({ id: DB });
const { container } = await database.containers.createIfNotExists({
  id: "c4", partitionKey: { paths: ["/pk"] },
});
log("db/container ready", DB);

// ---- timing helper: sequential ops, warmup excluded, errors counted ----
async function measureOp(op, surface, n, warmup, fn) {
  for (let i = 0; i < warmup; i++) await fn(i, true);
  const lats = [];
  let errs = 0;
  const t0All = performance.now();
  for (let i = 0; i < n; i++) {
    const t0 = performance.now();
    try { await fn(i, false); } catch (e) { errs++; noteErr(op, e); }
    lats.push(performance.now() - t0);
  }
  const wallMs = performance.now() - t0All;
  const s = summarize(lats);
  const opsPerSec = n / (wallMs / 1000);
  emit(surface, op, n, opsPerSec, s.p50, s.p95, s.p99, errs);
  return { s, opsPerSec };
}

const fieldText = (i, f) => `field-${i}-${f}:${"x".repeat(64)}`;

// ===========================================================================
// Phase 1 — CRYPTO FLOOR
// ===========================================================================
log("--- phase 1: crypto floor ---");
const kvEncrypt = await measureOp("kv_encrypt", "keyvault-crypto", N_FLOOR, WARM, () =>
  cryptoClient.encrypt({ algorithm: "RSA-OAEP-256", plaintext: crypto.randomBytes(DEK_BYTES) }));
const kvDecrypt = await measureOp("kv_decrypt", "keyvault-crypto", N_FLOOR, WARM, async () => {
  // fresh ciphertext per op so decrypt is real work, not a cache
  const ct = (await cryptoClient.encrypt({ algorithm: "RSA-OAEP-256", plaintext: crypto.randomBytes(DEK_BYTES) })).result;
  await cryptoClient.decrypt({ algorithm: "RSA-OAEP-256", ciphertext: ct });
});

// ===========================================================================
// Plaintext baselines — cosmos create / point-read, zero crypto
// ===========================================================================
log("--- plaintext baselines ---");
const plainCreate = await measureOp("cosmos_create_plaintext", "cosmos", N_DOCS, WARM,
  (i, warm) => container.items.create({ id: warm ? `plain-warm-${i}` : `plain-${i}`, pk: `p${i % 10}`, payload: "x".repeat(256) }));
const plainIds = Array.from({ length: N_DOCS }, (_, i) => `plain-${i}`);
const plainRead = await measureOp("cosmos_read_plaintext", "cosmos", N_DOCS, WARM,
  (i) => container.item(plainIds[i], `p${i % 10}`).read());

// ===========================================================================
// Phase 2 — ENVELOPE WRITE: DEK-per-doc, KV wrap + local AES x3 + create
// ===========================================================================
log("--- phase 2: envelope write ---");
const wLats = []; let wErrs = 0; const encDocIds = [];
{
  for (let i = 0; i < WARM; i++) {
    const dek = crypto.randomBytes(DEK_BYTES);
    const wrapped = (await cryptoClient.encrypt({ algorithm: "RSA-OAEP-256", plaintext: dek })).result;
    await container.items.create({ id: `warm-w-${i}`, pk: `p${i % 10}`, wrapped_dek: wrapped.toString("base64") });
  }
  const t0All = performance.now();
  for (let i = 0; i < N_DOCS; i++) {
    const t0 = performance.now();
    try {
      const dek = crypto.randomBytes(DEK_BYTES);
      const wrapped = (await cryptoClient.encrypt({ algorithm: "RSA-OAEP-256", plaintext: dek })).result;
      const fields = [1, 2, 3].map((f) => aesEncrypt(dek, Buffer.from(fieldText(i, f))));
      await container.items.create({
        id: `enc-w-${i}`, pk: `p${i % 10}`,
        wrapped_dek: wrapped.toString("base64"),
        f1: fields[0].toString("base64"),
        f2: fields[1].toString("base64"),
        f3: fields[2].toString("base64"),
      });
      encDocIds.push([`enc-w-${i}`, `p${i % 10}`]);
    } catch (e) { wErrs++; noteErr("envelope_write", e); }
    wLats.push(performance.now() - t0);
  }
  var wallW = performance.now() - t0All;
}
const envWriteOps = N_DOCS / (wallW / 1000);
const envWriteS = summarize(wLats);
emit("envelope", "envelope_write_kv_dek_per_doc", N_DOCS, envWriteOps,
  envWriteS.p50, envWriteS.p95, envWriteS.p99, wErrs, { kv_ops: N_DOCS });
const envelopeWrite = { opsPerSec: envWriteOps, s: envWriteS, errs: wErrs };

// ===========================================================================
// Phase 3 — ENVELOPE READ: read + KV decrypt + local AES x3
// ===========================================================================
log("--- phase 3: envelope read ---");
const rLats = []; let rErrs = 0;
{
  const t0All = performance.now();
  for (let i = 0; i < N_DOCS; i++) {
    const t0 = performance.now();
    try {
      const { resource: doc } = await container.item(encDocIds[i][0], encDocIds[i][1]).read();
      const dek = (await cryptoClient.decrypt({
        algorithm: "RSA-OAEP-256", ciphertext: Buffer.from(doc.wrapped_dek, "base64"),
      })).result;
      for (const f of ["f1", "f2", "f3"]) aesDecrypt(dek, Buffer.from(doc[f], "base64"));
    } catch (e) { rErrs++; noteErr("envelope_read", e); }
    rLats.push(performance.now() - t0);
  }
  var wallR = performance.now() - t0All;
}
const envReadOps = N_DOCS / (wallR / 1000);
const envReadS = summarize(rLats);
emit("envelope", "envelope_read_kv_decrypt_per_doc", N_DOCS, envReadOps,
  envReadS.p50, envReadS.p95, envReadS.p99, rErrs, { kv_ops: N_DOCS });
const envelopeRead = { opsPerSec: envReadOps, s: envReadS, errs: rErrs };

// ===========================================================================
// Phase 4 — KEY REUSE: wrapped DEK cached (one KV op), local crypto only
// ===========================================================================
log("--- phase 4: key reuse (cached DEK) ---");
const cLats = []; let cErrs = 0; const cachedIds = [];
{
  // ONE KV wrap for the whole phase; the DEK stays hot for local crypto.
  // (var: the key-reuse read loop below reuses the same hot DEK.)
  var dek = crypto.randomBytes(DEK_BYTES);
  const wrappedShared = (await cryptoClient.encrypt({ algorithm: "RSA-OAEP-256", plaintext: dek })).result;
  for (let i = 0; i < WARM; i++) {
    const fields = [1, 2, 3].map((f) => aesEncrypt(dek, Buffer.from(fieldText(`cw${i}`, f))));
    await container.items.create({
      id: `warm-c-${i}`, pk: `p${i % 10}`, wrapped_dek: wrappedShared.toString("base64"),
      f1: fields[0].toString("base64"), f2: fields[1].toString("base64"), f3: fields[2].toString("base64"),
    });
  }
  const t0All = performance.now();
  for (let i = 0; i < N_DOCS; i++) {
    const t0 = performance.now();
    try {
      const fields = [1, 2, 3].map((f) => aesEncrypt(dek, Buffer.from(fieldText(`cr${i}`, f))));
      await container.items.create({
        id: `enc-c-${i}`, pk: `p${i % 10}`, wrapped_dek: wrappedShared.toString("base64"),
        f1: fields[0].toString("base64"), f2: fields[1].toString("base64"), f3: fields[2].toString("base64"),
      });
      cachedIds.push([`enc-c-${i}`, `p${i % 10}`]);
    } catch (e) { cErrs++; noteErr("keyreuse_write", e); }
    cLats.push(performance.now() - t0);
  }
  var wallC = performance.now() - t0All;
}
const reuseWriteOps = N_DOCS / (wallC / 1000);
const reuseWriteS = summarize(cLats);
emit("envelope", "keyreuse_write_cached_dek", N_DOCS, reuseWriteOps,
  reuseWriteS.p50, reuseWriteS.p95, reuseWriteS.p99, cErrs, { kv_ops: 1 });
const keyReuseWrite = { opsPerSec: reuseWriteOps, s: reuseWriteS, errs: cErrs };

// key-reuse read: read + local AES x3, ZERO KV ops (DEK already hot)
const kLats = []; let kErrs = 0;
{
  const t0All = performance.now();
  for (let i = 0; i < N_DOCS; i++) {
    const t0 = performance.now();
    try {
      const { resource: doc } = await container.item(cachedIds[i][0], cachedIds[i][1]).read();
      for (const f of ["f1", "f2", "f3"]) aesDecrypt(dek, Buffer.from(doc[f], "base64"));
    } catch (e) { kErrs++; noteErr("keyreuse_read", e); }
    kLats.push(performance.now() - t0);
  }
  var wallK = performance.now() - t0All;
}
const reuseReadOps = N_DOCS / (wallK / 1000);
const reuseReadS = summarize(kLats);
emit("envelope", "keyreuse_read_cached_dek", N_DOCS, reuseReadOps,
  reuseReadS.p50, reuseReadS.p95, reuseReadS.p99, kErrs, { kv_ops: 0 });

// ===========================================================================
// Crypto-tax summary (stdout + jsonl meta row)
// ===========================================================================
const tax = {
  write: {
    plaintext_docs_per_sec: plainCreate.opsPerSec,
    envelope_docs_per_sec: envelopeWrite.opsPerSec,
    keyreuse_docs_per_sec: keyReuseWrite.opsPerSec,
    envelope_tax_multiplier: +(plainCreate.opsPerSec / envelopeWrite.opsPerSec).toFixed(2),
    keyreuse_tax_multiplier: +(plainCreate.opsPerSec / keyReuseWrite.opsPerSec).toFixed(2),
    keyreuse_speedup_vs_envelope: +(keyReuseWrite.opsPerSec / envelopeWrite.opsPerSec).toFixed(2),
  },
  read: {
    plaintext_docs_per_sec: plainRead.opsPerSec,
    envelope_docs_per_sec: envelopeRead.opsPerSec,
    keyreuse_docs_per_sec: reuseReadOps,
    envelope_tax_multiplier: +(plainRead.opsPerSec / envelopeRead.opsPerSec).toFixed(2),
    keyreuse_tax_multiplier: +(plainRead.opsPerSec / reuseReadOps).toFixed(2),
    keyreuse_speedup_vs_envelope: +(reuseReadOps / envelopeRead.opsPerSec).toFixed(2),
    b3_shared_substrate_plaintext_read: 4405,
  },
  crypto_floor: {
    kv_encrypt_ops_per_sec: +kvEncrypt.opsPerSec.toFixed(2),
    kv_encrypt_p50_ms: kvEncrypt.s.p50,
    kv_decrypt_ops_per_sec: +kvDecrypt.opsPerSec.toFixed(2),
    kv_decrypt_p50_ms: kvDecrypt.s.p50,
  },
  errors: errorLog.slice(0, 20),
  total_errors: errorCount,
};
fs.appendFileSync(OUT, JSON.stringify({ lane: LANE, surface: "meta", op: "crypto_tax_summary", tax, machine: MACHINE }) + "\n");
console.log(JSON.stringify(tax, null, 2));
log("DONE — results in", OUT);
if (errorCount > 0) { log(`NONFATAL: ${errorCount} errors`); process.exitCode = 1; }
