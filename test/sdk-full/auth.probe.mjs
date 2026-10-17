#!/usr/bin/env node
// auth.probe.mjs — SDK lane TS-6: probe smalt's bearer/OAuth fence with REAL
// @azure SDK auth machinery (@azure/identity TokenCredential + @azure/core-rest-pipeline).
//
// Follows ts-run.mjs's bootstrap (own substrate on private ports from the
// documented range 39000-39999), under an exclusive flock held by the caller
// (/tmp/smalt-substrate.lock). No lib/ or test/ edits; nothing committed.
//
// Exit: 0 all probes pass / 1 probe failure / 2 substrate never up / 3 harness failure.
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import http from "node:http";
import { createHmac } from "node:crypto";
import { fileURLToPath } from "node:url";

import {
  createPipelineRequest,
  bearerTokenAuthenticationPolicy,
  createEmptyPipeline,
  createDefaultHttpClient,
} from "@azure/core-rest-pipeline";

const REPO = pathResolve("../..");
const HERE = import.meta.dirname;
const LOG_DIR = path.join(HERE, ".logs");
fs.mkdirSync(LOG_DIR, { recursive: true });

import path from "node:path";
function pathResolve(rel) {
  return path.resolve(import.meta.dirname, rel);
}

// Private ports (docs/how-to/dev-loop.md private range, unclaimed slots).
const ARM_PORT = Number(process.env.SMALT_TS_ARM_PORT || 39681);
const AMQP_PORT = Number(process.env.SMALT_TS_AMQP_PORT || 39682);
const EH_PORT = Number(process.env.SMALT_TS_EH_PORT || 39683);
const EGRESS_PORT = Number(process.env.SMALT_TS_EGRESS_PORT || 39684);
const ARM_TLS_PORT = Number(process.env.SMALT_TS_ARM_TLS_PORT || 39685);
const POLL_DEADLINE_MS = 90_000;

const CERT_DIR = path.join(REPO, ".smalt/tls");
const CERT_FILE = path.join(CERT_DIR, "dev-cert.pem");
const KEY_FILE = path.join(CERT_DIR, "dev-key.pem");

const STS_SECRET = "smalt-auth-enforce-test-secret-0123456789abcdef";
const AUD = "https://management.azure.com";
const ISS_AUTHORITY = "https://login.microsoftonline.com";
const TENANT = "00000000-0000-0000-0000-000000000000";

const log = (...a) => console.log("[auth-probe]", ...a);

function tryConnect(port) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 1500 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });
}
const checkFree = async (port) => !(await tryConnect(port));

// -- JWT minting (HS256, same claim shape as test/auth_enforce_test.exs) ------
function b64u(buf) {
  return Buffer.from(buf).toString("base64url");
}
function mintJWT(claims, secret = STS_SECRET) {
  const header = b64u(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = b64u(JSON.stringify(claims));
  const sig = createHmac("sha256", secret)
    .update(`${header}.${payload}`)
    .digest("base64url");
  return `${header}.${payload}.${sig}`;
}
const now = () => Math.floor(Date.now() / 1000);
function mint(overrides = {}, secret = STS_SECRET) {
  const t = now();
  return mintJWT({
    aud: AUD,
    iss: `${ISS_AUTHORITY}/${TENANT}/v2.0`,
    iat: t,
    nbf: t,
    exp: t + 3600,
    appid: "00000000-0000-0000-0000-000000000000",
    azp: "00000000-0000-0000-0000-000000000000",
    oid: "00000000-0000-0000-0000-000000000001",
    sub: "00000000-0000-0000-0000-000000000001",
    tid: TENANT,
    roles: ["Contributor", "Owner"],
    ...overrides,
  }, secret);
}

// -- raw HTTP helper (needed for duplicate-Authorization probe) ---------------
function rawRequest(pathname, headers) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: "127.0.0.1", port: ARM_PORT, path: pathname, method: "GET", headers: {} },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body }));
      },
    );
    req.on("error", reject);
    for (const [k, v] of Object.entries(headers)) {
      // Array value => Node writes one header line per element (true duplicates).
      if (Array.isArray(v)) req.setHeader(k, v);
      else req.setHeader(k, v);
    }
    req.end();
  });
}

// -- @azure/identity custom TokenCredential over the smalt STS ----------------
class SmaltTokenCredential {
  constructor(token) { this.token = token; }
  async getToken(_scopes) {
    return { token: this.token, expiresOnTimestamp: Date.now() + 300_000 };
  }
}

const httpClient = createDefaultHttpClient();

async function pipelineGet(pathname, token) {
  const pipeline = createEmptyPipeline();
  pipeline.addPolicy(
    bearerTokenAuthenticationPolicy({
      credential: new SmaltTokenCredential(token),
      scopes: AUD,
    }),
  );
  const req = createPipelineRequest({
    // Real SDK policy refuses Bearer over http — use the ARM TLS twin.
    url: `https://localhost:${ARM_TLS_PORT}${pathname}`,
    method: "GET",
  });
  const res = await pipeline.sendRequest(httpClient, req);
  return {
    status: res.status,
    headers: res.headers.toString(),
    body: typeof res.bodyAsText === "string" ? res.bodyAsText : "",
  };
}

const results = [];
function record(name, pass, detail) {
  results.push({ name, pass, detail });
  log(`${pass ? "PASS" : "FAIL"} ${name}${detail ? " — " + detail : ""}`);
}

async function main() {
  // 0. Ports free?
  const ports = [ARM_PORT, AMQP_PORT, EH_PORT, EGRESS_PORT, ARM_TLS_PORT];
  for (const p of ports) {
    if (!(await checkFree(p))) {
      console.error(`[auth-probe] port ${p} occupied — fail-closed, not killing holder.`);
      process.exitCode = 3;
      return;
    }
  }

  // 1. Boot substrate (ts-run.mjs bootstrap + enforce-mode auth env).
  const bootEval = [
    `Application.put_env(:smalt, :auth_mode, :enforce)`,
    `Application.put_env(:smalt, :sts_signing_secret, "${STS_SECRET}")`,
    `Application.put_env(:smalt, :sb_shared_key, "${Buffer.from("ts6-auth-lane-shared-key").toString("base64")}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP_PORT}")`,
    `Application.put_env(:smalt, :amqp_port, ${AMQP_PORT})`,
    `Application.put_env(:smalt, :event_hubs_port, ${EH_PORT})`,
    `Application.put_env(:smalt, :arm_port, ${ARM_PORT})`,
    `Application.put_env(:smalt, :egress_port, ${EGRESS_PORT})`,
    `Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT})`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ].join("; ");

  const logPath = path.join(LOG_DIR, "auth-substrate.log");
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: {
      ...process.env,
      MIX_ENV: "test",
      SMALT_TLS_CERTFILE: CERT_FILE,
      SMALT_TLS_KEYFILE: KEY_FILE,
    },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);

  const killSubstrate = async (signal = "SIGTERM") => {
    try {
      if (child.pid && child.exitCode === null && !child.killed) {
        try { process.kill(-child.pid, signal); } catch { child.kill(signal); }
      }
    } catch {}
    if (signal !== "SIGKILL") {
      const dl = Date.now() + 5000;
      while (child.exitCode === null && Date.now() < dl) {
        await new Promise((r) => setTimeout(r, 200));
      }
      if (child.exitCode === null) await killSubstrate("SIGKILL");
    } else {
      await new Promise((resolve) => {
        try { child.once("close", resolve); } catch {}
        setTimeout(resolve, 5000);
      });
    }
  };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => { killSubstrate("SIGKILL"); process.exit(130); });
  }
  process.on("exit", () => {
    try { if (child.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch {}
  });

  // 2. Poll ARM port.
  const start = Date.now();
  for (;;) {
    if (await tryConnect(ARM_PORT)) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(`[auth-probe] substrate did not open ${ARM_PORT} in ${POLL_DEADLINE_MS / 1000}s. Log: ${logPath}`);
      await killSubstrate("SIGKILL");
      process.exitCode = 2;
      return;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  log(`substrate up on ${ports.join("/")} after ${Date.now() - start}ms`);

  try {
    await runProbes();
  } finally {
    await killSubstrate("SIGTERM");
  }

  const failed = results.filter((r) => !r.pass);
  console.log(`\n[auth-probe] ${results.length - failed.length}/${results.length} probes passed.`);
  if (failed.length) {
    for (const f of failed) console.error(`  FAIL ${f.name}: ${f.detail}`);
    process.exitCode = 1;
  }
}

async function runProbes() {
  const armBase = `http://127.0.0.1:${ARM_PORT}`;

  // Probe 1: STS token endpoint, client_credentials grant -> minted access_token.
  {
    const body = new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "probe-client",
      client_secret: "probe-secret",
    });
    const res = await fetch(`${armBase}/${TENANT}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    const json = await res.json();
    const ok = res.status === 200 && typeof json.access_token === "string" &&
      json.access_token.split(".").length === 3 && json.token_type === "Bearer";
    record("sts-token-endpoint-mint", ok,
      `status=${res.status} token_type=${json.token_type} expires_in=${json.expires_in} jwt_segments=${(json.access_token || "").split(".").length}`);
    var stsToken = json.access_token;
  }

  // Probe 2: minted Bearer via @azure/identity TokenCredential + core-rest-pipeline -> 200.
  {
    const r = await pipelineGet("/subscriptions?api-version=2021-04-01", stsToken);
    record("sdk-credential-arm-200", r.status === 200, `status=${r.status}`);
  }

  // Probe 3: tokenless -> 401 + WWW-Authenticate: Bearer challenge.
  {
    const res = await fetch(`${armBase}/subscriptions?api-version=2021-04-01`);
    const json = await res.json().catch(() => ({}));
    const challenge = res.headers.get("www-authenticate") || "";
    record("tokenless-401-challenge",
      res.status === 401 && /Bearer/i.test(challenge) && /AuthenticationFailed|InvalidAuthenticationToken/.test(json?.error?.code || ""),
      `status=${res.status} challenge="${challenge}" code=${json?.error?.code}`);
  }

  // Probe 4: tampered signature -> 401 SignatureVerificationFailed.
  {
    const tok = mint();
    const [h, p, s] = tok.split(".");
    const flipped = ((s.charCodeAt(0) ^ 0x01) & 0xff).toString(16).padStart(2, "0");
    const tampered = `${h}.${p}.${flipped}${s.slice(1)}`;
    const res = await fetch(`${armBase}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${tampered}` },
    });
    const json = await res.json().catch(() => ({}));
    record("tampered-signature-401",
      res.status === 401 && /SignatureVerificationFailed/.test(json?.error?.message || ""),
      `status=${res.status} message=${json?.error?.message}`);
  }

  // Probe 5: expired token (exp in the past) -> 401 TokenExpired.
  {
    const t = now();
    const tok = mint({ iat: t - 7200, nbf: t - 7200, exp: t - 3600 });
    const res = await fetch(`${armBase}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${tok}` },
    });
    const json = await res.json().catch(() => ({}));
    record("expired-token-401",
      res.status === 401 && /TokenExpired/.test(json?.error?.message || ""),
      `status=${res.status} message=${json?.error?.message}`);
  }

  // Probe 6: future nbf (token not yet valid) -> 401.
  {
    const t = now();
    const tok = mint({ nbf: t + 600 });
    const res = await fetch(`${armBase}/subscriptions?api-version=2021-04-01`, {
      headers: { authorization: `Bearer ${tok}` },
    });
    const json = await res.json().catch(() => ({}));
    const msg = json?.error?.message || "";
    record("future-nbf-401", res.status === 401, `status=${res.status} message=${msg}`);
  }

  // Probe 7: duplicate Authorization headers -> fail-closed refusal.
  {
    const tok = mint();
    const r = await rawRequest("/subscriptions?api-version=2021-04-01", {
      authorization: [`Bearer ${tok}`, `Bearer ${tok}`],
    });
    const json = JSON.parse(r.body || "{}");
    record("duplicate-authorization-refused",
      r.status === 401 && /MalformedBearerHeader/.test(json?.error?.message || ""),
      `status=${r.status} message=${json?.error?.message}`);
  }

  // Probe 8: api-version missing -> 400 MissingApiVersionParameter.
  {
    const tok = mint();
    const res = await fetch(`${armBase}/subscriptions`, {
      headers: { authorization: `Bearer ${tok}` },
    });
    const json = await res.json().catch(() => ({}));
    record("missing-apiversion-400",
      res.status === 400 && /MissingApiVersionParameter/.test(json?.error?.code || ""),
      `status=${res.status} code=${json?.error?.code}`);
  }

  // Probe 9: stale api-version -> 400 InvalidApiVersionParameter naming latest.
  // /subscriptions is presence-only by documented design (router.ex lens-2
  // receipt), so the stale-version leg targets a Registry-admitted type:
  // resourcegroups (latest 2021-04-01).
  {
    const tok = mint();
    const res = await fetch(`${armBase}/subscriptions/${TENANT}/resourcegroups?api-version=2017-05-10`, {
      headers: { authorization: `Bearer ${tok}` },
    });
    const json = await res.json().catch(() => ({}));
    const msg = json?.error?.message || "";
    record("stale-apiversion-400",
      res.status === 400 && /InvalidApiVersionParameter/.test(json?.error?.code || "") && /2021-04-01/.test(msg),
      `status=${res.status} code=${json?.error?.code} message=${msg}`);
  }
}

main().catch((e) => {
  console.error("[auth-probe] harness error:", e);
  process.exitCode = 3;
});
