// keyvault.probe.mjs — TS-7 lane: real @azure/keyvault-keys against the smalt
// substrate. Follows ts-run.mjs conventions: canonical ports, .smalt/tls CA via
// NODE_EXTRA_CA_CERTS, bearer minted from the substrate's own ARM STS.
// Run: NODE_EXTRA_CA_CERTS=../../.smalt/tls/ca-cert.pem node keyvault.probe.mjs
import { KeyClient, CryptographyClient } from "@azure/keyvault-keys";
import * as crypto_module from "node:crypto";
import net from "node:net";

// Lane-351: port env overrides (mirror ts-run.mjs SMALT_TS_* convention).
const ARM = process.env.SMALT_TS_ARM || "http://127.0.0.1:9443";
const VAULT = process.env.SMALT_TS_ARM_TLS || "https://127.0.0.1:9444";
const EGRESS = process.env.SMALT_TS_EGRESS || "http://127.0.0.1:8443";
const MEASUREMENT = "11".repeat(32);

const results = [];
let failures = 0;

function record(name, status, evidence) {
  const ok = status === "PASS" || status === "DIVERGENCE";
  if (status !== "PASS" && status !== "DIVERGENCE") failures++;
  results.push({ name, status, evidence });
  console.log(`[${status}] ${name}${evidence ? " — " + evidence : ""}`);
}

// Bearer token from the substrate's own STS (HS256, aud management.azure.com).
async function mintBearer() {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: "sdk-ts7",
    client_secret: "dev",
  });
  const res = await fetch(`${ARM}/oauth2/v2.0/token`, { method: "POST", body });
  if (!res.ok) throw new Error(`STS mint failed ${res.status}: ${await res.text()}`);
  return (await res.json()).access_token;
}

// Attestation token for SKR release: POST /attest/:type with the seeded
// baseline measurement; substrate signs the claims (ReceiptSigner).
async function mintAttestationToken() {
  const res = await fetch(`${EGRESS}/attest/maa-v10`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ measurement: MEASUREMENT }),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`attest failed ${res.status}: ${text}`);
  const j = JSON.parse(text);
  return j.token || j.access_token || j.jwt || j;
}

class StsCredential {
  constructor(token) {
    this.token = token;
  }
  async getToken() {
    return { token: this.token, expiresOnTimestamp: Date.now() + 3600_000 };
  }
}

class StaticCredential {
  constructor(token) {
    this.token = token;
  }
  async getToken() {
    return { token: this.token, expiresOnTimestamp: Date.now() + 3600_000 };
  }
}

// Substrate preflight: this probe attaches, it does not boot. Exit 2
// (substrate down) loud, never a fake "1 = test fail" on a dead plane.
const preflightPorts = [
  ["ARM", Number(new URL(ARM).port) || 80],
  ["VAULT", Number(new URL(VAULT).port) || 443],
];
for (const [name, port] of preflightPorts) {
  await new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 2000 });
    s.once("connect", () => { s.destroy(); resolve(); });
    s.once("timeout", () => {
      s.destroy();
      console.error(`[keyvault-probe] substrate down: no listener on 127.0.0.1:${port} (${name}). Exit 2.`);
      process.exit(2);
      resolve();
    });
    s.once("error", () => {
      console.error(`[keyvault-probe] substrate down: no listener on 127.0.0.1:${port} (${name}). Exit 2.`);
      process.exit(2);
      resolve();
    });
  });
}

// Guard the unguarded top-level mint: a rejection here would exit 1
// (harness error masquerading as test fail) — exit 3 per contract.
let bearer;
try {
  bearer = await mintBearer();
} catch (e) {
  console.error(`[keyvault-probe] harness error minting bearer: ${e?.name}: ${e?.message}`);
  process.exit(3);
}
console.log("bearer minted, len=" + bearer.length);

// Real SDK 4.10 uses CHALLENGE-BASED auth: it sends "Bearer " with an empty
// token until the server answers 401 + WWW-Authenticate. The substrate never
// issues that challenge, so the token is never attached (witnessed via relay:
// Authorization len 7). Force the header in the Sign phase to exercise the
// envelope with the real SDK anyway.
function forceBearer(token) {
  return {
    name: "force-bearer",
    sendRequest(req, next) {
      req.headers.set("authorization", `Bearer ${token}`);
      return next(req);
    },
  };
}
function addForceBearer(keyClient, token) {
  const pipeline = keyClient.client?.pipeline;
  if (pipeline) pipeline.addPolicy(forceBearer(token), { phase: "Sign" });
}

const client = new KeyClient(VAULT, new StsCredential(bearer), {
  allowInsecureConnection: true,
  // Lane-351: SDK 4.10 challenge-resource check requires a subdomain of the
  // challenge host (endsWith "."+hostname) — an IP-literal vault host can
  // never pass, port-independent. Emulator: disable, like allowInsecureConnection.
  disableChallengeResourceVerification: true,
  retryOptions: { maxRetries: 0 },
});

const raw = async (method, path, token, body) => {
  const res = await fetch(VAULT + path, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "x-ms-server-encrypted": "true",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await text_or(res);
  return { status: res.status, headers: res.headers, text };
};
async function text_or(res) {
  try {
    return await res.text();
  } catch {
    return "";
  }
}

// ---------------------------------------------------------------------------
// 1. createKey — real SDK sends PUT /keys/:name; substrate only implements
//    POST /keys/:name/create.
// ---------------------------------------------------------------------------
const kname = "ts7-rsa";
let created;
try {
  created = await client.createKey(kname, "RSA");
  record(
    "createKey (PUT /keys/:name)",
    "PASS",
    `kty=${created.key.kty} kid=${created.kid} (substrate accepted PUT)`,
  );
} catch (e) {
  const r = await raw("PUT", `/keys/${kname}?api-version=7.4`, bearer, {
    kty: "RSA",
  });
  record(
    "createKey (PUT /keys/:name)",
    "FAIL",
    `${e.message}; raw PUT -> ${r.status} ${r.text.slice(0, 200)}`,
  );
}

// Fallback: substrate-native create route.
let kid;
try {
  const r = await raw("POST", `/keys/${kname}/create?api-version=7.4`, bearer, {
    kty: "RSA",
  });
  const j = JSON.parse(r.text);
  kid = j.key && j.key.kid;
  record(
    "POST /keys/:name/create (substrate-native)",
    r.status === 200 ? "PASS" : "FAIL",
    `status=${r.status} kid=${kid ?? "?"}`,
  );
} catch (e) {
  record("POST /keys/:name/create (substrate-native)", "FAIL", e.message);
}

// ---------------------------------------------------------------------------
// 2. getKey
// ---------------------------------------------------------------------------
try {
  const key = await client.getKey(kname);
  record("getKey", key && key.key ? "PASS" : "FAIL", `kid=${key.kid} kty=${key.key.kty}`);
} catch (e) {
  record("getKey", "FAIL", e.message);
}

// ---------------------------------------------------------------------------
// 3. listKeys
// ---------------------------------------------------------------------------
try {
  const names = [];
  for await (const k of client.listPropertiesOfKeys()) {
    names.push(k.name);
    if (names.length >= 5) break;
  }
  record(
    "listKeys",
    names.includes(kname) ? "PASS" : "FAIL",
    `first names: ${names.join(",")}`,
  );
} catch (e) {
  record("listKeys", "FAIL", e.message);
}

// ---------------------------------------------------------------------------
// 4. updateKeyProperties (PATCH /keys/:name/:version)
// ---------------------------------------------------------------------------
try {
  await client.updateKeyProperties(kname, "", { enabled: false });
  const after = await client.getKey(kname);
  record(
    "updateKeyProperties(enabled=false)",
    after.properties.enabled === false ? "PASS" : "DIVERGENCE",
    `enabled after update=${after.properties.enabled}`,
  );
  await client.updateKeyProperties(kname, "", { enabled: true });
} catch (e) {
  record("updateKeyProperties", "FAIL", e.message);
}

// ---------------------------------------------------------------------------
// 5. listVersions
// ---------------------------------------------------------------------------
try {
  const vers = [];
  for await (const p of client.listPropertiesOfKeyVersions(kname)) {
    vers.push(p.version);
  }
  record("listVersions", vers.length >= 1 ? "PASS" : "FAIL", `count=${vers.length}`);
} catch (e) {
  record("listVersions", "FAIL", e.message);
}

// ---------------------------------------------------------------------------
// 6. releaseKey — probe the 200 envelope (lane 19 changed it: plain JSON via
//    send_json, no blob headers). SDK credential = fresh attestation token.
// ---------------------------------------------------------------------------
try {
  // create a release-policy key first via substrate-native route
  await raw("POST", `/keys/ts7-skr/create?api-version=7.4`, bearer, {
    kty: "RSA",
    release_policy: {
      anyOf: [{ claim: "x-ms-compliance-status", equals: "azure-compliant-cvm" }],
    },
  });
  const attestation = await mintAttestationToken();
  const skrClient = new KeyClient(VAULT, new StaticCredential(attestation), {
    allowInsecureConnection: true,
    disableChallengeResourceVerification: true,
    retryOptions: { maxRetries: 0 },
    // SHIM-COURT parity note: emulator enforces real AKV 7.x surface; SDK
    // default 2025-07-01 returns 400 on releaseKey. serviceVersion pins the
    // per-client api-version.
    serviceVersion: "7.4",
  });
  addForceBearer(skrClient, attestation);
  const rel = await skrClient.releaseKey("ts7-skr", "https://example.com/recipient");
  record(
    "releaseKey",
    "PASS",
    `policy=${rel.policy} value(64 chars)=${String(rel.value).slice(0, 64)}`,
  );
} catch (e) {
  const r = await raw("POST", `/keys/ts7-skr/release?api-version=7.4`, bearer, {
    context: "https://example.com/recipient",
  });
  record(
    "releaseKey",
    "FAIL",
    `${e.message}; raw release (bearer, no attestation) -> ${r.status} ${r.text.slice(0, 200)}`,
  );
}

// Raw envelope check of a successful release: does the 200 carry blob headers?
try {
  const attestation = await mintAttestationToken();
  const res = await fetch(VAULT + "/keys/ts7-skr/release?api-version=7.4", {
    method: "POST",
    headers: { authorization: `Bearer ${attestation}`, "content-type": "application/json" },
    body: JSON.stringify({ context: "https://example.com/recipient" }),
  });
  const hdrs = [...res.headers.entries()].filter(([h]) => h.startsWith("x-ms-"));
  const j = await res.json();
  record(
    "release 200 envelope (headers + body)",
    res.status === 200 && Object.keys(j).length > 0 ? "PASS" : "FAIL",
    `status=${res.status} x-ms-* headers=[${hdrs.map((h) => h[0]).join(",") || "none"}] bodyKeys=${Object.keys(j).join(",")}`,
  );
} catch (e) {
  record("release 200 envelope (headers + body)", "FAIL", e.message);
}

// ---------------------------------------------------------------------------
// 7. Rotation policy surface — what exists vs 404s.
// ---------------------------------------------------------------------------
for (const [label, method, path] of [
  ["getRotationPolicy (GET /keys/:name/rotationpolicy)", "GET", `/keys/ts7-rsa/rotationpolicy?api-version=7.4`],
  ["putRotationPolicy (PUT /keys/:name/rotationpolicy)", "PUT", `/keys/ts7-rsa/rotationpolicy?api-version=7.4`],
  ["SDK getKeyRotationPolicy", "SDK", "get"],
  ["SDK rotateKey", "SDK", "rotate"],
]) {
  try {
    if (method === "SDK") {
      if (label.includes("RotationPolicy")) {
        const pol = await client.getKeyRotationPolicy(kname);
        console.log(`  rotation policy body: ${JSON.stringify(pol)}`);
      } else {
        await client.rotateKey(kname);
      }
    } else {
      const r = await raw(method, path, bearer, method === "PUT" ? { attributes: { expiryTime: "P30D" } } : undefined);
      record(label, r.status === 200 ? "PASS" : "DIVERGENCE",
        `${r.status} ${r.text.slice(0, 140)}`);
    }
    if (method !== "SDK") continue;
  } catch (e) {
    const m = String(e.message);
    record(label, m.includes("404") ? "DIVERGENCE" : "FAIL", m.slice(0, 160));
  }
}

// ---------------------------------------------------------------------------
// 8. deleteKey / purgeDeletedKey
// ---------------------------------------------------------------------------
try {
  // SDK 4.10 exposes beginDeleteKey (polling LRO), no direct deleteKey; the
  // substrate has no DELETE /keys/:name route either way.
  const poller = await client.beginDeleteKey(kname);
  await poller.pollUntilDone();
  record("deleteKey (beginDeleteKey LRO)", "PASS", "accepted");
} catch (e) {
  const r = await raw("DELETE", `/keys/${kname}?api-version=7.4`, bearer);
  record(
    "deleteKey (beginDeleteKey LRO)",
    "FAIL",
    `${e.message}; raw DELETE -> ${r.status} ${r.text.slice(0, 120)}`,
  );
}
try {
  await client.purgeDeletedKey(kname);
  record("purgeDeletedKey", "FAIL", "purge accepted (soft-delete surface unimplemented?)");
} catch (e) {
  record("purgeDeletedKey", "DIVERGENCE", String(e.message).slice(0, 160));
}

// ---------------------------------------------------------------------------
// 9. CryptographyClient — encrypt/decrypt/wrap/unwrap/sign/verify
// ---------------------------------------------------------------------------
try {
  const key = await client.getKey(kname);
  // deleteKey above may have removed it — recreate via substrate-native route
  if (!key) throw new Error("key gone after delete");
} catch {
  /* fall through to recreate */
}
try {
  await raw("POST", `/keys/ts7-crypto/create?api-version=7.4`, bearer, { kty: "RSA" });
  const cryptoClient = new CryptographyClient(
    `${VAULT}/keys/ts7-crypto`,
    new StsCredential(bearer),
    { disableChallengeResourceVerification: true, allowInsecureConnection: true },
  );
  addForceBearer(cryptoClient, bearer);
  const plain = Buffer.from("ts7 crypto probe payload");
  const enc = await cryptoClient.encrypt({ algorithm: "RSA-OAEP-256", plaintext: plain });
  record("crypto encrypt RSA-OAEP-256", "PASS", `ct bytes=${enc.result.length}`);
  const dec = await cryptoClient.decrypt({ algorithm: "RSA-OAEP-256", ciphertext: enc.result });
  record(
    "crypto decrypt round-trip",
    Buffer.compare(dec.result, plain) === 0 ? "PASS" : "FAIL",
    `pt bytes=${dec.result.length}`,
  );
  const cek = Buffer.from("0".repeat(32));
  const wrapped = await cryptoClient.wrapKey("RSA-OAEP-256", cek);
  record("crypto wrapKey", "PASS", `wrapped bytes=${wrapped.result.length}`);
  const unwrapped = await cryptoClient.unwrapKey("RSA-OAEP-256", wrapped.result);
  record(
    "crypto unwrapKey round-trip",
    Buffer.compare(unwrapped.result, cek) === 0 ? "PASS" : "FAIL",
    "",
  );
  const data = Buffer.from("ts7 sign payload");
  const sig = await cryptoClient.sign("RS256", data);
  record("crypto sign RS256", "PASS", `sig bytes=${sig.result.length}`);
  const verified = await cryptoClient.verify("RS256", data, sig.result);
  record(
    "crypto verify RS256",
    verified.result === true ? "PASS" : "FAIL",
    `valid=${verified.result}`,
  );
  // Interop: verify the substrate's RS256 signature with Node's real RSA
  // implementation using the public JWK (n, e) from getKey.
  {
    const jwk = (await client.getKey("ts7-crypto")).key;
    // SDK 4.10 JsonWebKey exposes n/e as Buffers — re-encode to base64url JWK.
    const b64u = (v) => Buffer.from(v).toString("base64url");
    const pub = crypto_module.createPublicKey({
      key: { kty: "RSA", n: b64u(jwk.n), e: b64u(jwk.e) },
      format: "jwk",
    });
    const digest = crypto_module.createHash("sha256").update(data).digest();
    const ok = crypto_module.verify("sha256", digest, pub, sig.result);
    record(
      "RS256 signature interoperability (Node crypto, PKCS1v1.5 over SHA-256 digest)",
      ok ? "PASS" : "DIVERGENCE",
      ok ? "node verifies substrate signature" : "substrate signature is NOT a standard RS256 signature",
    );
  }
} catch (e) {
  record("CryptographyClient block", "FAIL", String(e.message).slice(0, 300));
}

console.log(`\nSummary: ${results.length} probes, ${failures} FAIL, ${results.length - failures} PASS/DIVERGENCE`);
process.exitCode = failures > 0 ? 1 : 0;
