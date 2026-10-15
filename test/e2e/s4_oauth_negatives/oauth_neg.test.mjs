// oauth_neg.test.mjs — E2E auth-adversary court (s4_oauth_negatives).
// Vendored @azure/identity + raw REST against the live smalt substrate.
//
// POSITIVE control first: ClientSecretCredential (authorityHost = substrate
// TLS twin https://localhost:9444, NODE_EXTRA_CA_CERTS = dev CA; documented
// fallback: raw token POST if the SDK's https enforcement blocks) obtains a
// token → GET /subscriptions with Bearer → 200.
//
// NEGATIVE matrix — every case records {case, observed, verdict} where verdict
// is SECURITY-PASS (rejected as expected) or KNOWN-GAP (accepted/revealed
// state). The honest gap register IS the deliverable; a KNOWN-GAP never
// fails the suite (unless NEG_STRICT=1), it documents reality.
//
// Phases (driven by run.sh):
//   NEG_PHASE=a — positive + crafted-claim negatives (secret A is known to
//                 the harness, so HS256 tokens with adversarial claims can
//                 be forged with a VALID signature — this isolates claim
//                 validation from signature validation) + per-service
//                 missing-Authorization probes; token A is saved for phase b.
//   NEG_PHASE=b — substrate B (different :sts_signing_secret) healthy-control
//                 + present substrate A's token to B → pin actual behavior.
//
// Exit codes: 0 all cases observed (gaps allowed, register written) /
// 1 positive control failed or a case could not be observed / 3 harness
// misconfiguration. Never a silent pass: every case lands in the receipt.
import { createRequire } from "node:module";
import path from "node:path";
import fs from "node:fs";
import crypto from "node:crypto";
import { test, after } from "node:test";
import assert from "node:assert/strict";

const HERE = import.meta.dirname;
// Vendored SDKs (zero installs): default to the repo's test/sdk-full tree,
// overridable via SMALT_SDK_ROOT (a dir containing node_modules/@azure/*).
const SDK_ROOT =
  process.env.SMALT_SDK_ROOT ||
  path.join(HERE, "..", "..", "sdk-full");
const require = createRequire(path.join(SDK_ROOT, "package.json"));
const { ClientSecretCredential } = require("@azure/identity");

const ARM_HTTP = process.env.NEG_ARM_HTTP || "http://127.0.0.1:9443";
const ARM_TLS = process.env.NEG_ARM_TLS || "https://localhost:9444";
const EGRESS = process.env.NEG_EGRESS || "http://127.0.0.1:8443";
const PHASE = process.env.NEG_PHASE || "a";
const SECRET_A = process.env.NEG_SECRET_A || "smalt-neg-court-secret-A-0123456789abcdef";
const TOKEN_A_FILE = process.env.NEG_TOKEN_A_FILE || path.join(HERE, ".work", "tokenA.txt");
const RECEIPT_FILE = process.env.NEG_RECEIPT_FILE || path.join(HERE, "receipt.json");
const STAMP = new Date().toISOString();

const T = (ms) => AbortSignal.timeout(ms);
const records = [];

function record(cse, observed, verdict, note = "") {
  records.push({ ts: STAMP, phase: PHASE, case: cse, observed, verdict, note });
  console.log(`  [${verdict}] ${PHASE}/${cse}: observed=${observed}${note ? " — " + note : ""}`);
}

// Gap = anything other than an auth rejection. 401/403 = auth enforced.
function verdictFor(status) {
  return status === 401 || status === 403 ? "SECURITY-PASS" : "KNOWN-GAP";
}

// Enforce-mode assertion: an auth rejection must be 401 WITH a
// WWW-Authenticate: Bearer challenge. Throws on any weaker rejection.
function assertAuthChallenge(res, label) {
  const www = res.headers.get("www-authenticate") || "";
  assert.equal(res.status, 401, `${label}: expected 401, got ${res.status}`);
  assert.match(www, /Bearer/i, `${label}: expected WWW-Authenticate: Bearer challenge`);
}

after(() => {
  const gaps = records.filter((r) => r.verdict === "KNOWN-GAP");
  const receipt = {
    court: "s4_oauth_negatives",
    phase: PHASE,
    finishedAt: STAMP,
    total: records.length,
    securityPass: records.filter((r) => r.verdict === "SECURITY-PASS").length,
    knownGaps: gaps.length,
    cases: records,
  };
  fs.mkdirSync(path.dirname(RECEIPT_FILE), { recursive: true });
  fs.writeFileSync(RECEIPT_FILE, JSON.stringify(receipt, null, 2) + "\n");
  console.log(`\n== s4_oauth_negatives phase ${PHASE} gap register (${STAMP}) ==`);
  for (const r of records) {
    console.log(
      `${r.verdict.padEnd(14)} ${PHASE}/${r.case} — observed: ${r.observed}${r.note ? " — " + r.note : ""}`,
    );
  }
  console.log(
    `total=${records.length} SECURITY-PASS=${receipt.securityPass} KNOWN-GAP=${receipt.knownGaps} ` +
    `receipt=${RECEIPT_FILE}`,
  );
  if (gaps.length > 0) {
    // Enforce-mode substrate: KNOWN-GAP is no longer tolerated by default
    // (NEG_STRICT is now the standing expectation; the 8 former gaps are
    // fixed by Smalt.Auth.Bearer). Set NEG_STRICT=0 to tolerate gaps.
    if (process.env.NEG_STRICT === "0") {
      console.log("NEG_STRICT=0: tolerating KNOWN-GAP case(s)");
    } else {
    console.error(`NEG_STRICT: ${gaps.length} KNOWN-GAP case(s) — failing`);
    process.exitCode = 1;
    }
  }
});

// --- JWT helpers -------------------------------------------------------------

const b64u = (buf) => Buffer.from(buf).toString("base64url");

function craftToken(secret, claims, header = { alg: "HS256", typ: "JWT" }) {
  const signingInput = `${b64u(JSON.stringify(header))}.${b64u(JSON.stringify(claims))}`;
  const sig = crypto.createHmac("sha256", secret).update(signingInput).digest("base64url");
  return `${signingInput}.${sig}`;
}

function jwtPayload(token) {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
}

// Positive control token acquisition: vendored @azure/identity first; if the
// SDK's https/authority enforcement blocks, documented fallback = raw token
// POST against the same endpoint. The fallback used is disclosed in the note.
let sdkWorked = false;

async function acquireToken(scope = "https://management.azure.com/.default") {
  const cred = new ClientSecretCredential(
    "00000000-0000-0000-0000-000000000000",
    "neg-court-client",
    "neg-court-secret",
    { authorityHost: ARM_TLS },
  );
  try {
    const tok = await cred.getToken(scope, { abortSignal: T(20_000) });
    sdkWorked = true;
    return { token: tok.token, via: "@azure/identity ClientSecretCredential (TLS :9444)" };
  } catch (sdkErr) {
    // Documented fallback path: raw token POST (the endpoint is http-capable
    // on :9443). The SDK failure itself is disclosed, never swallowed.
    const res = await fetch(`${ARM_HTTP}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: "neg-court-client",
        client_secret: "neg-court-secret",
        scope,
      }),
      signal: T(20_000),
    });
    const body = await res.json();
    if (!res.ok || !body.access_token) {
      throw new Error(
        `token acquisition failed via SDK (${sdkErr.message}) AND raw fallback (HTTP ${res.status})`,
      );
    }
    return { token: body.access_token, via: `raw POST fallback (SDK blocked: ${sdkErr.message})` };
  }
}

// --- Phase A -----------------------------------------------------------------

if (PHASE === "a") {
  test("positive control: SDK (or documented raw fallback) token → GET /subscriptions Bearer → 200", { timeout: 60_000 }, async () => {
    const { token, via } = await acquireToken();
    const payload = jwtPayload(token);
    record("positive.token-acquisition", via, "SECURITY-PASS",
      `aud=${payload.aud} exp in ${Math.round(payload.exp - Date.now() / 1000)}s`);
    assert.ok(payload.exp > Date.now() / 1000, "token not expired");
    assert.equal(payload.aud, "https://management.azure.com", "aud is ARM audience");

    const res = await fetch(`${ARM_HTTP}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${token}` },
      signal: T(20_000),
    });
    record("positive.subscriptions-bearer", `GET /subscriptions with Bearer → ${res.status}`,
      res.status === 200 ? "SECURITY-PASS" : "KNOWN-GAP");
    assert.equal(res.status, 200, `positive control must be 200, got ${res.status}`);

    fs.mkdirSync(path.dirname(TOKEN_A_FILE), { recursive: true });
    fs.writeFileSync(TOKEN_A_FILE, token);
  });

  test("negative: expired token (valid HS256 sig by secret A, exp = now-1h) → ARM", { timeout: 30_000 }, async () => {
    const now = Math.floor(Date.now() / 1000);
    const expired = craftToken(SECRET_A, {
      aud: "https://management.azure.com",
      iss: "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0",
      iat: now - 7200, nbf: now - 7200, exp: now - 3600,
      oid: "00000000-0000-0000-0000-000000000001", sub: "00000000-0000-0000-0000-000000000001",
      tid: "00000000-0000-0000-0000-000000000000", roles: ["Contributor"],
    });
    const res = await fetch(`${ARM_HTTP}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${expired}` },
      signal: T(20_000),
    });
    record("negative.expired-token", `GET /subscriptions with exp-past token → ${res.status}`,
      verdictFor(res.status), "validly signed by secret A; only exp is adversarial — 401 TokenExpired");
    assertAuthChallenge(res, "negative.expired-token");
  });

  test("negative: tampered signature (flip a char in the JWT signature) → ARM", { timeout: 30_000 }, async () => {
    const { token } = await acquireToken();
    const parts = token.split(".");
    const sig = Buffer.from(parts[2], "base64url");
    sig[0] = sig[0] ^ 0x01;
    const tampered = `${parts[0]}.${parts[1]}.${sig.toString("base64url")}`;
    const res = await fetch(`${ARM_HTTP}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${tampered}` },
      signal: T(20_000),
    });
    record("negative.tampered-signature", `GET /subscriptions with tampered sig → ${res.status}`,
      verdictFor(res.status));
    assertAuthChallenge(res, "negative.tampered-signature");
  });

  test("negative: wrong-audience token (valid sig by secret A, aud = vault.smalt.local) → ARM", { timeout: 30_000 }, async () => {
    const now = Math.floor(Date.now() / 1000);
    const wrongAud = craftToken(SECRET_A, {
      aud: "https://vault.smalt.local",
      iss: "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0",
      iat: now, nbf: now, exp: now + 3600,
      oid: "00000000-0000-0000-0000-000000000001", sub: "00000000-0000-0000-0000-000000000001",
      tid: "00000000-0000-0000-0000-000000000000", roles: ["Contributor"],
    });
    const res = await fetch(`${ARM_HTTP}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${wrongAud}` },
      signal: T(20_000),
    });
    record("negative.wrong-aud", `GET /subscriptions with aud=vault token → ${res.status}`,
      verdictFor(res.status));
    assertAuthChallenge(res, "negative.wrong-aud");
  });

  test("negative: missing Authorization on every service family — per-service pin", { timeout: 60_000 }, async () => {
    // ARM GET /subscriptions
    const arm = await fetch(`${ARM_HTTP}/subscriptions?api-version=2021-04-01`, { signal: T(20_000) });
    record("negative.no-auth.arm-subscriptions", `GET /subscriptions anonymous → ${arm.status}`,
      verdictFor(arm.status));
    assertAuthChallenge(arm, "negative.no-auth.arm-subscriptions");

    // Cosmos POST a doc anonymously (fresh db/coll ids)
    const db = `negdb${Date.now()}`;
    const cos = await fetch(`${EGRESS}/dbs/${db}/colls/${db}/docs`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id: "anon-doc", anonymous: true }),
      signal: T(20_000),
    });
    record("negative.no-auth.cosmos-doc", `POST /dbs/${db}/colls/${db}/docs anonymous → ${cos.status}`,
      verdictFor(cos.status));
    assertAuthChallenge(cos, "negative.no-auth.cosmos-doc");

    // Blob: create container anonymously, then PUT a blob anonymously.
    // x-ms-version is the substrate's wire-shape gate (400 MissingXMsVersion
    // otherwise) — supplied so the observation isolates AUTH, not shape.
    const account = "negacct";
    const container = `neg-container-${Date.now()}`;
    const mk = await fetch(`${EGRESS}/${account}/${container}`, {
      method: "PUT",
      headers: { "x-ms-version": "2021-08-06" },
      signal: T(20_000),
    });
    record("negative.no-auth.blob-create-container",
      `PUT /${account}/${container} anonymous → ${mk.status}`, verdictFor(mk.status),
      mk.status === 401 ? "401 = Smalt.Auth.Bearer gate (precedes x-ms-version wire gate)" : "");
    assertAuthChallenge(mk, "negative.no-auth.blob-create-container");
    const put = await fetch(`${EGRESS}/${account}/${container}/anon.txt`, {
      method: "PUT",
      headers: { "x-ms-blob-type": "BlockBlob", "x-ms-version": "2021-08-06" },
      body: "anonymous write",
      signal: T(20_000),
    });
    record("negative.no-auth.blob-put", `PUT /${account}/${container}/anon.txt anonymous → ${put.status}`,
      verdictFor(put.status),
      put.status === 401 ? "401 = Smalt.Auth.Bearer gate (precedes x-ms-version wire gate)" : "");
    assertAuthChallenge(put, "negative.no-auth.blob-put");

    // SKR release without auth: substrate requires an attested MAA bearer —
    // expected 403 UnauthorizedAttestation (contrast: this family DOES gate).
    const keyName = `neg-skr-${Date.now()}`;
    await fetch(`${EGRESS}/keys/${keyName}/create`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ kty: "RSA-HSM", release_policy: { allowed_operations: ["release"] } }),
      signal: T(20_000),
    });
    const rel = await fetch(`${EGRESS}/keys/${keyName}/release`, { method: "POST", signal: T(20_000) });
    record("negative.no-auth.skr-release", `POST /keys/:name/release anonymous → ${rel.status}`,
      verdictFor(rel.status),
      rel.status === 401 ? "401 = Smalt.Auth.Bearer gate (SKR attestation gate now preceded by bearer gate)" : "");
    assertAuthChallenge(rel, "negative.no-auth.skr-release");
  });
}

// --- Phase B (substrate B, different :sts_signing_secret) ---------------------

if (PHASE === "b") {
  test("substrate B healthy control: B-minted token → GET /subscriptions → 200", { timeout: 60_000 }, async () => {
    const { token } = await acquireToken();
    const res = await fetch(`${ARM_HTTP}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${token}` },
      signal: T(20_000),
    });
    record("cross.control-b-token", `substrate B token on B → ${res.status}`,
      res.status === 200 ? "SECURITY-PASS" : "KNOWN-GAP",
      "control: B must serve its own tokens");
    assert.equal(res.status, 200, `substrate B control must be 200, got ${res.status}`);
  });

  test("negative: substrate A's token presented to substrate B (different signing secret)", { timeout: 30_000 }, async () => {
    const tokenA = fs.readFileSync(TOKEN_A_FILE, "utf8").trim();
    assert.ok(tokenA.split(".").length === 3, "token A present from phase a");
    const res = await fetch(`${ARM_HTTP}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${tokenA}` },
      signal: T(20_000),
    });
    record("cross.a-token-on-b", `substrate A token on B (secret mismatch) → ${res.status}`,
      verdictFor(res.status),
      res.status === 401
        ? "B validates HS256 signatures — secret rotation invalidates outstanding tokens"
        : "B accepted a token it cannot have signed — substrate does not validate STS signatures");
    assertAuthChallenge(res, "cross.a-token-on-b");
  });
}
