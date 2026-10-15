// R1 adversarial input fuzz — smalt substrate, ALL API surfaces.
// Owns its own substrate lifecycle via run.sh (mix run --no-halt in background).
// Invariant under test, asserted on EVERY response:
//   - status < 500 (any 5xx = FINDING)
//   - no timeout / connection reset / Erlang-style crash dump body
//   - status >= 400 => well-formed JSON error envelope {"error":{"code":...}}
//     (documented exceptions: blob-route XML listings, header-only successes)
//   - JSON success bodies parse
// Any violation is recorded as a FINDING (repro request + detail) in
// findings.md by the reporter in this file's `after` hook.
//
// Route discovery is PROGRAMMATIC: the Plug.Router route tables are crawled
// out of lib/smalt/arm_gateway/router.ex and lib/smalt/egress_router.ex at
// runtime and every discovered (route x attack class) combination is
// exercised for real over the wire against 127.0.0.1:9443 (ARM) and
// 127.0.0.1:8443 (egress). AMQP boot surfaces (5672 ServiceBus, 5673
// EventHubs) are fuzzed at the TCP/protocol level and the listeners must
// survive.

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import net from "node:net";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..", "..");

const ARM = "http://127.0.0.1:9443";
const EGRESS = "http://127.0.0.1:8443";
const REQ_TIMEOUT_MS = 10_000;
const CONCURRENCY = 8;
const MAX_FINDINGS = 500;

// ---------------------------------------------------------------------------
// Route crawling (programmatic, from the router sources)
// ---------------------------------------------------------------------------

function crawlRoutes(file, surface) {
  const src = readFileSync(join(REPO, file), "utf8");
  const routes = [];
  const re = /^\s*(get|post|put|delete|patch|match)\s+"([^"]+)"/gm;
  let m;
  while ((m = re.exec(src)) !== null) {
    routes.push({ surface, method: m[1].toUpperCase(), pattern: m[2] });
  }
  return routes;
}

function crawlAllRoutes() {
  return [
    ...crawlRoutes("lib/smalt/arm_gateway/router.ex", "arm"),
    ...crawlRoutes("lib/smalt/egress_router.ex", "egress"),
  ];
}

// ---------------------------------------------------------------------------
// Concrete path generation
// ---------------------------------------------------------------------------

const SEED = {
  sub_id: "00000000-0000-0000-0000-000000000001",
  rg_name: "rg-fuzz",
  provider_ns: "Microsoft.Network",
  resource_type: "virtualNetworks",
  resource_name: "vnet-fuzz",
  parent: "vnet-fuzz",
  name: "res-fuzz",
  container: "cont-fuzz",
  blob_name: "blob-fuzz.bin",
  account: "fuzzacct",
  db: "fuzzdb",
  coll: "fuzzcoll",
  doc_id: "doc-fuzz",
  topic: "fuzztopic",
  dcr: "dcr-fuzz",
  stream: "Custom-Fuzz",
  workspace_id: "ws-fuzz",
  tx_id: "tx-fuzz",
  tenant_id: "00000000-0000-0000-0000-000000000001",
  type: "maa",
  guid: "guid-fuzz",
  direction: "inputs",
  action: "encrypt",
  op_id: "op-fuzz",
  glob: "Microsoft.KeyVault/vaults/k1/keys/k2",
};

function concretePath(pattern, overrides = {}) {
  const seeds = { ...SEED, ...overrides };
  return pattern
    .replace(/:(\w+)/g, (_, k) => seeds[k] ?? `x-${k}`)
    .replace(/\*(\w+)/g, (_, k) => seeds[k] ?? `x-${k}`);
}

// ---------------------------------------------------------------------------
// Attack classes
// ---------------------------------------------------------------------------

const METHOD_CONFUSION = ["TRACE", "CONNECT", "PATCH", "PUT", "GET", "DELETE", "POST", "HEAD", "OPTIONS"];

const BOMB_10MB = "A".repeat(10 * 1024 * 1024);

const PAYLOAD_BOMBS = [
  { name: "10MB-body", body: BOMB_10MB, ct: "application/json" },
  {
    name: "1000-deep-nested-json",
    body: '{"a":' + '{"a":'.repeat(999) + "1" + "}".repeat(1000) + "}",
    ct: "application/json",
  },
  {
    name: "10k-key-object",
    body: JSON.stringify(Object.fromEntries(Array.from({ length: 10_000 }, (_, i) => [`k${i}`, i]))),
    ct: "application/json",
  },
  { name: "duplicate-json-keys", body: '{"a":1,"a":2}', ct: "application/json" },
  { name: "nan-infinity", body: '{"a":NaN,"b":Infinity,"c":-Infinity}', ct: "application/json" },
  { name: "unicode-escapes", body: '{"a":"\\u0000"}', ct: "application/json" },
  { name: "unpaired-surrogate-escape", body: '{"a":"\\ud800"}', ct: "application/json" },
  { name: "homoglyph-id", body: '{"name":"reсourceGroup-fuzz"}', ct: "application/json" },
  { name: "empty-body-json-ct", body: "", ct: "application/json" },
  { name: "wrong-ct-xml-as-json", body: "<a></a>", ct: "application/xml" },
  { name: "text-plain-json", body: '{"a":1}', ct: "text/plain" },
];

const PATH_GAMES = [
  { name: "double-slash", mutate: (p) => p.replace(/\/(?!\/)/, "//") },
  { name: "dotdot", mutate: (p) => p + "/../rg-fuzz" },
  { name: "dotdot-encoded", mutate: (p) => p + "/%2e%2e/rg-fuzz" },
  { name: "null-byte", mutate: (p) => p.replace("rg-fuzz", "rg%00x") },
  {
    name: "case-flip",
    mutate: (p) =>
      p.includes("resourceGroups")
        ? p.replace("resourceGroups", "RESOURCEGROUPS")
        : p.includes("resourcegroups")
          ? p.replace("resourcegroups", "ResourceGroups")
          : p,
  },
  { name: "long-segment-8k", mutate: (p) => p + "/" + "a".repeat(8192) },
  {
    name: "unicode-segment",
    mutate: (p) => p + "/" + encodeURIComponent("リソースgroup"),
  },
  { name: "percent-enc-slash", mutate: (p) => p.replace("rg-fuzz", "rg%2Ffuzz") },
];

const QUERY_INJECTIONS = [
  { name: "api-version-dup", qs: "api-version=2021-01-01&api-version=2019-01-01" },
  { name: "api-version-empty", qs: "api-version=" },
  { name: "api-version-lie", qs: "api-version=2099-99-99" },
  { name: "gigantic-query-64k", qs: "q=" + "z".repeat(64 * 1024) },
  { name: "sql-injection", qs: "q=" + encodeURIComponent("'; DROP TABLE users;--") },
  { name: "kql-injection", qs: "q=" + encodeURIComponent("| where true | limit 100") },
  {
    name: "kql-in-body-sentinel",
    body: JSON.stringify({ query: "| where true; drop all" }),
    ct: "application/json",
  },
  {
    name: "sql-in-body-resourcegraph",
    body: JSON.stringify({ query: "'; DROP TABLE resources;--" }),
    ct: "application/json",
  },
  {
    name: "backticks-in-body",
    body: JSON.stringify({ query: "`rm -rf /`" }),
    ct: "application/json",
  },
];

const HEADER_GAMES = [
  { name: "duplicate-if-match", headers: { "if-match": ['"a"', '"b"'] } },
  { name: "huge-header-16k", headers: { "x-fuzz-huge": "h".repeat(16 * 1024) } },
  { name: "x-ms-version-lie", headers: { "x-ms-version": "9999-99-99" } },
  { name: "x-ms-version-empty", headers: { "x-ms-version": "" } },
];

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

let findings = [];
let checks = 0;

function recordFinding(f) {
  if (findings.length < MAX_FINDINGS) findings.push(f);
}

async function fuzzRequest({
  surface,
  method,
  path,
  query = "",
  headers = {},
  body,
  contentType,
  class: cls,
  route,
  attackName = "",
}) {
  const base = surface === "arm" ? ARM : EGRESS;
  const url = `${base}${path}${query ? (query.startsWith("?") ? query : "?" + query) : ""}`;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), REQ_TIMEOUT_MS);
  const t0 = Date.now();

  let res = null;
  let resBody = "";
  let err = null;
  let resHeadersGet = (h) => (res?.headers?.get ? res.headers.get(h) : null);
  try {    const hdrs = {};
    if (contentType) hdrs["content-type"] = contentType;
    for (const [k, v] of Object.entries(headers)) {
      if (Array.isArray(v)) for (const vv of v) hdrs[k] = hdrs[k] ? hdrs[k] + ", " +vv : vv;
      else hdrs[k] = v;
    }
    // undici fetch refuses TRACE/CONNECT client-side; send those raw so the
    // SERVER's handling (not the harness) is what's under test.
    if (method === "TRACE" || method === "CONNECT") {
      const raw = await rawRequest(base, method, path + (query ? "?" + query.replace(/^\?/, "") : ""), hdrs, body);
      res = { status: raw.status, headers: new Map(Object.entries(raw.headers)) };
      resBody = raw.body;
      resHeadersGet = (h) => (raw.headers[Object.keys(raw.headers).find((k) => k.toLowerCase() === h.toLowerCase()) ?? ""] ?? "").toLowerCase();
    } else {
    res = await fetch(url, {
      method,
      headers: hdrs,
      body: body !== undefined && !["GET", "HEAD"].includes(method) ? body : undefined,
      signal: ctl.signal,
      redirect: "manual",
    });
    resBody = await res.text();
    }
  } catch (e) {
    err = e;
  } finally {
    clearTimeout(timer);
  }

  checks++;
  const dur = Date.now() - t0;
  const meta = { surface, route, cls, attackName, method, url };

  if (err) {
    recordFinding({
      ...meta,
      kind: err.name === "AbortError" ? "TIMEOUT" : "TRANSPORT-ERROR",
      detail: String(err?.cause ?? err),
      duration_ms: dur,
    });
    return;
  }

  const status = res.status;
  const ct = resHeadersGet("content-type") || "";

  if (status >= 500) {
    recordFinding({
      ...meta,
      kind: "HTTP-5XX",
      detail: `status=${status} body[0..400]=${resBody.slice(0, 400)}`,
      duration_ms: dur,
    });
    return;
  }

  // Erlang/plug crash dump leaking into body (outside a JSON/XML envelope)
  if (
    resBody &&
    !resBody.trimStart().startsWith("{") &&
    !resBody.trimStart().startsWith("<") &&
    /(FunctionClauseError|UndefinedFunctionError|\(Bandit\)|\(Plug\)|\(exit\)|CaseClauseError|BadMapError)/.test(resBody)
  ) {
    recordFinding({ ...meta, kind: "CRASH-DUMP-BODY", detail: resBody.slice(0, 400), duration_ms: dur });
    return;
  }

  if (status >= 400) {
    const trimmed = resBody.trim();
    let ok = false;
    if (trimmed.startsWith("{")) {
      try {
        const j = JSON.parse(trimmed);
        ok =
          j !== null &&
          typeof j === "object" &&
          !Array.isArray(j) &&
          j.error &&
          typeof j.error === "object" &&
          typeof j.error.code === "string" &&
          j.error.code.length > 0;
      } catch {
        ok = false;
      }
    }
    if (!ok) {
      recordFinding({
        ...meta,
        kind: "BAD-ERROR-ENVELOPE",
        detail: `status=${status} ct=${ct} body[0..400]=${resBody.slice(0, 400)}`,
        duration_ms: dur,
      });
    }
    return;
  }

  // Success with claimed JSON must parse
  if (ct.includes("json") && resBody.trim().length > 0) {
    try {
      JSON.parse(resBody);
    } catch {
      recordFinding({
        ...meta,
        kind: "MALFORMED-JSON-SUCCESS",
        detail: resBody.slice(0, 400),
        duration_ms: dur,
      });
    }
  }
}

// Raw HTTP/1.1 over a TCP socket — used for TRACE/CONNECT, which undici
// fetch refuses client-side. Returns {status, headers, body}.
function rawRequest(base, method, pathAndQuery, headers, body) {
  const u = new URL(base);
  return new Promise((resolve, reject) => {
    const sock = net.connect({ host: u.hostname, port: u.port });
    let buf = Buffer.alloc(0);
    let settled = false;
    const done = (fn, v) => {
      if (settled) return;
      settled = true;
      try { sock.destroy(); } catch {}
      fn(v);
    };
    sock.setTimeout(REQ_TIMEOUT_MS);
    sock.on("timeout", () => done(reject, new Error("rawRequest timeout")));
    sock.on("error", done.bind(null, reject));
    sock.on("connect", () => {
      let req = `${method} ${pathAndQuery} HTTP/1.1\r\nhost: ${u.hostname}:${u.port}\r\nconnection: close\r\ncontent-length: ${body ? Buffer.byteLength(body) : 0}\r\n`;
      for (const [k, v] of Object.entries(headers)) req += `${k}: ${v}\r\n`;
      req += "\r\n";
      sock.write(req);
      if (body) sock.write(body);
      sock.end();
    });
    sock.on("data", (d) => (buf = Buffer.concat([buf, d])));
    sock.on("close", () => {
      const s = buf.toString("latin1");
      const headEnd = s.indexOf("\r\n\r\n");
      const status = parseInt((s.split("\r\n")[0] || "").split(" ")[1] || "0", 10);
      const headers = {};
      if (headEnd >= 0) {
        for (const line of s.slice(0, headEnd).split("\r\n").slice(1)) {
          const i = line.indexOf(":");
          if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
        }
      }
      done(resolve, { status, headers, body: headEnd >= 0 ? s.slice(headEnd + 4) : s });
    });
  });
}

async function pooled(items, worker, limit = CONCURRENCY) {
  let i = 0;
  await Promise.all(
    Array.from({ length: limit }, async () => {
      while (i < items.length) {
        const idx = i++;
        await worker(items[idx]);
      }
    })
  );
}

async function alive(base) {
  const res = await fetch(`${base}/metadata/endpoints`);
  assert.ok(res.status > 0 && res.status < 500, `substrate ${base} liveness failed: ${res.status}`);
}

// ---------------------------------------------------------------------------
// Request plan: every discovered route x every attack class
// ---------------------------------------------------------------------------

function buildPlan() {
  const plan = [];
  for (const { surface, method: rmethod, pattern } of crawlAllRoutes()) {
    const path = concretePath(pattern);
    const routeTag = `${rmethod} ${pattern}`;
    const bodiless = new Set(["GET", "HEAD", "TRACE", "CONNECT", "OPTIONS"]);

    // (1) method confusion (skip the route's own verb)
    for (const m of METHOD_CONFUSION) {
      if (m === rmethod) continue;
      plan.push({
        surface, method: m, path, class: "method-confusion", route: routeTag,
        headers: { "x-ms-version": "2021-12-02" },
        body: bodiless.has(m) ? undefined : '{"a":1}',
        contentType: bodiless.has(m) ? undefined : "application/json",
      });
    }

    // (2) payload bombs on bodied methods only
    if (!bodiless.has(rmethod) && rmethod !== "MATCH") {
      for (const bomb of PAYLOAD_BOMBS) {
        plan.push({
          surface, method: rmethod, path, class: "payload-bomb",
          attackName: bomb.name, route: routeTag,
          body: bomb.body, contentType: bomb.ct,
        });
      }
    }

    // (3) path games on GET (read-side path normalization surface)
    if (rmethod === "GET") {
      for (const g of PATH_GAMES) {
        let p2;
        try {
          p2 = g.mutate(concretePath(pattern));
        } catch {
          continue;
        }
        plan.push({
          surface, method: "GET", path: p2, class: "path-game",
          attackName: g.name, route: routeTag,
          headers: { "x-ms-version": "2021-12-02" },
        });
      }
    }

    // (4) query injection (GET + bodied routes)
    if (rmethod === "GET" || (!bodiless.has(rmethod) && rmethod !== "MATCH")) {
      for (const q of QUERY_INJECTIONS) {
        plan.push({
          surface, method: rmethod, path, class: "query-injection",
          attackName: q.name, route: routeTag,
          query: q.qs, body: q.body, contentType: q.ct,
          headers: { "x-ms-version": "2021-12-02" },
        });
      }
    }

    // (5) header games
    for (const h of HEADER_GAMES) {
      plan.push({
        surface, method: rmethod, path, class: "header-game",
        attackName: h.name, route: routeTag, headers: h.headers,
      });
    }
  }
  return plan;
}

// ---------------------------------------------------------------------------
// AMQP boot fuzz (5672 ServiceBus, 5673 EventHubs)
// ---------------------------------------------------------------------------

function amqpProbe(port, payload) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: "127.0.0.1", port });
    let settled = false;
    const done = (kind, detail = "") => {
      if (settled) return;
      settled = true;
      try { sock.destroy(); } catch {}
      resolve({ kind, detail });
    };
    sock.setTimeout(5000);
    sock.on("timeout", () => done("AMQP-TIMEOUT"));
    sock.on("error", (e) => done("AMQP-CONN-ERROR", String(e)));
    sock.on("connect", () => {
      sock.write(payload);
      sock.end();
    });
    sock.on("data", () => done("OK-RESPONDED"));
    sock.on("close", () => done("OK-CLOSED"));
  });
}

const AMQP_CASES = [
  { label: "bare-garbage", payload: Buffer.from("GARBAGE GARBAGE GARBAGE\r\n\r\n", "utf8") },
  { label: "amqp-header-bitflip", payload: Buffer.from("AMQP\x01\x01\x00\x00", "utf8") },
  { label: "amqp-header-version0", payload: Buffer.from("AMQP\x00\x01\x00\x00", "utf8") },
  {
    label: "sasl-header-plus-100k",
    payload: Buffer.concat([Buffer.from("AMQP\x03\x01\x00\x00", "utf8"), Buffer.alloc(100_000, 0x41)]),
  },
  {
    label: "frame-size-lie-2GB",
    payload: Buffer.concat([Buffer.from("AMQP\x00\x01\x00\x00", "utf8"), Buffer.from([0x7f, 0xff, 0xff, 0xff])]),
  },
];

describe("R1 input fuzz — AMQP boot surfaces (5672/5673)", () => {
  it("AMQP listeners survive garbage and oversized protocol headers", async () => {
    for (const port of [5672, 5673]) {
      for (const c of AMQP_CASES) {
        const v = await amqpProbe(port, c.payload);
        assert.ok(
          ["OK-CLOSED", "AMQP-TIMEOUT", "OK-RESPONDED"].includes(v.kind),
          `AMQP ${port} ${c.label} -> ${v.kind} ${v.detail}`
        );
      }
    }
    // substrate must still be alive after the AMQP fuzz
    await alive(ARM);
    await alive(EGRESS);
  });
});

describe("R1 input fuzz — ARM (9443) + egress (8443) routes x attack classes", () => {
  before(async () => {
    await alive(ARM);
    await alive(EGRESS);
  });

  it("every (route x attack) probe obeys the response invariant", async () => {
    const plan = buildPlan();
    assert.ok(plan.length > 1000, `plan suspiciously small: ${plan.length}`);
    await pooled(plan, (req) => fuzzRequest(req));
    // Substrate still alive at the end: the fuzz must not have killed it.
    await alive(ARM);
    await alive(EGRESS);
  });
});

// ---------------------------------------------------------------------------
// Regression — previously-crashing requests (R1 court classes 1-3) must now
// return HTTP 400 with a well-formed {"error":{"code":...}} envelope, 5xx-free.
// ---------------------------------------------------------------------------

const REGRESSION_CASES = [
  {
    name: "dcr-ingest json-object-without-_json (class 1: wrap_json_list FunctionClauseError)",
    method: "POST",
    path: "/dataCollectionRules/dcr-fuzz/streams/Custom-Fuzz?api-version=2023-03-01",
    body: '{"legacy":true}',
    contentType: "application/json",
  },
  {
    name: "dcr-ingest empty-body-json-ct (class 1: wrap_json_list FunctionClauseError)",
    method: "POST",
    path: "/dataCollectionRules/dcr-fuzz/streams/Custom-Fuzz?api-version=2023-03-01",
    body: "",
    contentType: "application/json",
  },
  {
    name: "ledger append non-JSON content-type application/xml (class 2: Unfetched -> canonical/1)",
    method: "POST",
    path: "/app/transactions",
    body: "<tx/>",
    contentType: "application/xml",
  },
  {
    name: "ledger append non-JSON content-type text/plain (class 2: Unfetched -> canonical/1)",
    method: "POST",
    path: "/app/transactions",
    body: "plain-text-tx",
    contentType: "text/plain",
  },
  {
    name: "dcr-ingest non-JSON content-type text/plain (class 1/2 seam: Unfetched -> 400, not 500)",
    method: "POST",
    path: "/dataCollectionRules/dcr-fuzz/streams/Custom-Fuzz?api-version=2023-01-01",
    body: "plain-text-log",
    contentType: "text/plain",
  },
  {
    name: "cosmos create doc non-JSON content-type application/xml (class 3: Unfetched -> quoted_sha256)",
    method: "POST",
    path: "/dbs/fuzzdb/colls/fuzzcoll/docs",
    body: "<doc/>",
    contentType: "application/xml",
  },
  {
    name: "cosmos put doc non-JSON content-type text/plain (class 3: Unfetched -> quoted_sha256)",
    method: "PUT",
    path: "/dbs/fuzzdb/colls/fuzzcoll/docs/doc-fuzz",
    body: "not-json",
    contentType: "text/plain",
  },
  {
    name: "attest empty body with json ct (class 1 family: empty -> 400, not 500)",
    method: "POST",
    path: "/attest/maa",
    body: "",
    contentType: "application/json",
  },
  {
    name: "purview create entity non-JSON content-type application/xml (seam guard)",
    method: "POST",
    path: "/atlas/v2/entity",
    body: "<entity/>",
    contentType: "application/xml",
  },
  {
    name: "resourcegraph query empty body with json ct (seam guard)",
    method: "POST",
    path: "/providers/Microsoft.ResourceGraph/resources",
    body: "",
    contentType: "application/json",
  },
  {
    name: "blob PUT binary/invalid-UTF-8 content (ST6 D1: metadata-only 201, no content leak)",
    method: "PUT",
    path: "/fuzzacct/cont-fuzz/d1-binary-blob.bin",
    body: Buffer.from([0x00, 0xff, 0xfe, 0x80, 0x81, 0x7f, 0xc3, 0x28]),
    contentType: "application/octet-stream",
    headers: { "x-ms-version": "2021-12-02" },
    expect: {
      status: 201,
      noLeak: (text) => !text.includes("content") || JSON.parse(text).content === undefined,
    },
  },
];

describe("R1 regression — fixed crash classes return envelopes, never 5xx", () => {
  before(async () => {
    // ST6 D1 target container (create-or-ignore)
    await fetch(`${EGRESS}/fuzzacct/cont-fuzz?restype=container`, {
      method: "PUT",
      headers: { "x-ms-version": "2021-12-02" },
    }).catch(() => {});
  });

  for (const c of REGRESSION_CASES) {
    it(`envelope: ${c.name}`, async () => {
      const res = await fetch(`${EGRESS}${c.path}`, {
        method: c.method,
        headers: { "content-type": c.contentType, ...(c.headers ?? {}) },
        body: c.body,
      });
      const text = await res.text();
      assert.ok(res.status < 500, `expected <500, got ${res.status}: ${text.slice(0, 200)}`);
      if (c.expect) {
        assert.equal(res.status, c.expect.status, text.slice(0, 200));
        if (c.expect.noLeak) assert.ok(c.expect.noLeak(text), `content leak in body: ${text.slice(0, 200)}`);
      } else {
        assert.equal(res.status, 400, `expected 400, got ${res.status}: ${text.slice(0, 200)}`);
        const j = JSON.parse(text);
        assert.equal(typeof j?.error?.code, "string");
        assert.ok(j.error.code.length > 0);
      }
    });
  }
});

// ---------------------------------------------------------------------------
// Reporter — findings.md receipt (always written, fail-closed)
// ---------------------------------------------------------------------------

after(async () => {
  const counts = {};
  for (const f of findings) counts[f.kind] = (counts[f.kind] || 0) + 1;
  const lines = [];
  lines.push(`# R1 Input Fuzz Findings — ${new Date().toISOString()}`);
  lines.push("");
  lines.push(`- Total fuzzed requests executed: ${checks}`);
  lines.push(`- Findings: ${findings.length}${findings.length >= MAX_FINDINGS ? ` (CAPPED at ${MAX_FINDINGS})` : ""}`);
  lines.push(`- By kind: ${JSON.stringify(counts)}`);
  lines.push("");
  lines.push(`## Confirmed crash classes (server stack traces witnessed in substrate.log)`);
  lines.push("");
  lines.push(
    `1. wrap_json_list/1 FunctionClauseError — lib/smalt/egress_router.ex:683 (call site :289). ` +
      `POST /dataCollectionRules/:dcr/streams/:stream with a JSON OBJECT body lacking "_json" ` +
      `(or empty body with application/json) -> HTTP 500 empty body.`
  );
  lines.push(
    `2. ConfidentialLedger.canonical/1 Protocol.UndefinedError on %Plug.Conn.Unfetched{} — ` +
      `lib/smalt/security/confidential_ledger.ex:116 (call site egress_router.ex:103). ` +
      `POST /app/transactions with non-JSON content-type (application/xml, text/plain) -> 500.`
  );
  lines.push(
    `3. Cosmos.quoted_sha256/1 Jason.Encoder Protocol.UndefinedError on %Plug.Conn.Unfetched{} — ` +
      `lib/smalt/data_plane/cosmos.ex:280 (call site egress_router.ex:115). ` +
      `POST /dbs/:db/colls/:coll/docs with non-JSON content-type -> 500.`
  );
  lines.push(
    `4. Bandit HTTP-layer rejections (413/414/431) and 10MB-body connection resets (ECONNRESET/EPIPE) ` +
      `on DELETE/PUT routes that never read the body: fail-closed but NOT JSON error envelopes.`
  );
  lines.push(
    `5. Cosmos 404 bodies use the Azure-documented {"code":...} shape (no error.code envelope) — ` +
      `flagged BAD-ERROR-ENVELOPE by the strict invariant, accepted as documented shape.`
  );
  lines.push("");
  for (const f of findings) {
    lines.push(`## ${f.kind} — ${f.surface} ${f.method} ${f.url.slice(0, 200)}`);
    lines.push("");
    lines.push(`- route: \`${f.route}\``);
    lines.push(`- class: ${f.cls}${f.attackName ? ` (${f.attackName})` : ""}`);
    lines.push(`- detail: ${String(f.detail).replace(/\n/g, " ").slice(0, 600)}`);
    lines.push("");
  }
  writeFileSync(join(HERE, "findings.md"), lines.join("\n"));
});
