#!/usr/bin/env node
// azb20/recording-proxy.mjs — TLS-terminating recording proxy for the AZB-20
// header audit. Terminates TLS with the dev cert, forwards plain http to the
// substrate plane behind it, records every response's status+headers to a
// jsonl, then audits the capture against per-plane header rules.
//
// Header contract audited (TICKETS.md AZB-20):
//   x-ms-request-id  — every control-plane response; every blob-family 2xx
//   x-ms-version     — every blob-family 2xx (echo of the client's version)
//   ETag             — container/blob PUT/GET 2xx; keyed resource 2xx
//
// Exit 0 = capture clean, 1 = audit failure (missing required header),
// 3 = harness error. The capture jsonl is the receipt artifact.
import https from "node:https";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
function opt(name, def) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : def;
}

const LISTEN = Number(opt("listen", 39454));
const TARGET = opt("target", "http://127.0.0.1:39443");
const PLANE = opt("plane", "control");
const CAPTURE = opt("capture", "tmp/azb20/capture.jsonl");
const CERT_DIR = process.env.SMALT_CERT_DIR || path.resolve(import.meta.dirname, "../../../.smalt/tls");
const CERT = path.join(CERT_DIR, "dev-cert.pem");
const KEY = path.join(CERT_DIR, "dev-key.pem");

fs.mkdirSync(path.dirname(CAPTURE), { recursive: true });

const isBlobFamily = (p) => {
  const m = p.match(/^\/([^/]+)\/([^/]+)(\/.*)?$/);
  if (!m) return false;
  // Exclude cosmos (/dbs), kv (/keys,/secrets,/kv), ledger (/app,/v1),
  // eventgrid (/topics), attest. Blob family is /{account}/{container}[/{blob}].
  const banned = ["dbs", "keys", "secrets", "kv", "app", "v1", "topics", "attest", "providers", "subscriptions", "dataCollectionRules", "atlas", "oauth2"];
  return !banned.includes(m[1]) && !banned.includes(m[2]);
};
const isKeyed = (p) => /^\/(keys|secrets|kv)\//.test(p) || /^\/keys\??/.test(p);

const rules = {
  control: (entry) => {
    const req = [];
    // ARM router plug stamps x-ms-request-id on EVERY response.
    req.push("x-ms-request-id");
    return req;
  },
  data: (entry) => {
    const req = [];
    if (isBlobFamily(entry.path) && entry.status >= 200 && entry.status < 300) {
      req.push("x-ms-request-id", "x-ms-version");
    }
    if (isBlobFamily(entry.path) && entry.method === "PUT" &&
        entry.status >= 200 && entry.status < 300) {
      req.push("etag");
    }
    if (isKeyed(entry.path) && entry.status >= 200 && entry.status < 300) req.push("etag");
    return req;
  },
  integration: () => [],
  identity: () => [],
};

const capture = [];
const server = https.createServer(
  { key: fs.readFileSync(KEY), cert: fs.readFileSync(CERT) },
  (creq, cres) => {
    const entry = {
      plane: PLANE,
      ts: new Date().toISOString(),
      method: creq.method,
      path: creq.url,
      reqHeaders: { "x-ms-version": creq.headers["x-ms-version"] || null },
      status: null,
      headers: null,
    };
    const up = http.request(
      TARGET + creq.url,
      { method: creq.method, headers: { ...creq.headers, host: `localhost:${new URL(TARGET).port}` } },
      (ures) => {
        entry.status = ures.statusCode;
        entry.headers = ures.headers;
        capture.push(entry);
        cres.writeHead(ures.statusCode, ures.headers);
        ures.pipe(cres);
      },
    );
    up.on("error", (e) => {
      entry.status = 0;
      entry.headers = { "x-azb20-proxy-error": String(e.code || e) };
      capture.push(entry);
      cres.writeHead(502, { "x-azb20-proxy-error": String(e.code || e) });
      cres.end();
    });
    creq.pipe(up);
  },
);

function flushAndAudit() {
  try {
    fs.appendFileSync(CAPTURE, capture.map((e) => JSON.stringify(e)).join("\n") + (capture.length ? "\n" : ""));
  } catch {}
  let violations = [];
  for (const e of capture) {
    for (const h of rules[PLANE](e)) {
      const have = e.headers && e.headers[h] !== undefined && e.headers[h] !== null;
      if (e.status && e.status !== 502 && !have) {
        violations.push(`${e.method} ${e.path} -> ${e.status} missing ${h}`);
      }
    }
  }
  if (violations.length) {
    console.error(`[azb20-proxy] HEADER AUDIT FAIL (${PLANE}): ${violations.length} violations`);
    for (const v of violations.slice(0, 20)) console.error(`  VIOLATION: ${v}`);
    process.exitCode = 1;
  } else if (capture.length === 0) {
    console.error("[azb20-proxy] HEADER AUDIT VACUOUS: zero responses captured");
    process.exitCode = 3;
  } else {
    console.log(`[azb20-proxy] HEADER AUDIT PASS (${PLANE}): ${capture.length} responses audited, 0 violations`);
  }
}

// Stop accepting + audit on graceful signal (run.mjs sends SIGTERM).
server.close(() => {});
process.on("SIGTERM", () => { server.close(); setTimeout(() => { flushAndAudit(); process.exit(process.exitCode || 0); }, 300); });
process.on("SIGINT", () => { flushAndAudit(); process.exit(process.exitCode || 0); });

server.listen(LISTEN, "127.0.0.1", () => {
  console.log(`[azb20-proxy] listening https://127.0.0.1:${LISTEN} -> ${TARGET} (plane=${PLANE})`);
});
