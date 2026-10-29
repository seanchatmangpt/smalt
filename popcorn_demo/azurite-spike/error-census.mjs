// W30-D - differential error-shape census: smalt (9444 TLS twin, SharedKey per
// verification/ts/kd114-sharedkey.probe.cjs) vs Azurite (devstoreaccount1).
// 10 named error shapes on the blob face; one jsonl row per shape appended to
// error-census.jsonl (same dir). Smalt substrate is never restarted.
//
// Run: node popcorn_demo/azurite-spike/error-census.mjs
"use strict";
import fs from "node:fs";
import crypto from "node:crypto";
import https from "node:https";
import http from "node:http";

const OUT = new URL("./error-census.jsonl", import.meta.url).pathname;

const SMALT_ACCOUNT = "popcorn";
const SMALT_KEY =
  process.env.SMALT_SB_SHARED_KEY ||
  crypto.createHash("sha256").update(SMALT_ACCOUNT + "smalt-dev-sb").digest("base64");

const BACKENDS = [
  {
    id: "smalt",
    endpoint: "https://127.0.0.1:9444",
    account: "popcorn",
    key: SMALT_KEY,
    agent: new https.Agent({ rejectUnauthorized: false, keepAlive: false }),
  },
  {
    id: "azurite",
    endpoint: "http://127.0.0.1:10000",
    account: "devstoreaccount1",
    key: "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==",
    agent: new http.Agent({ keepAlive: false }),
  },
];

const VERSION = "2021-12-02";

function sign(backend, method, headers, path, query) {
  const cl = headers["content-length"];
  const contentLength = cl && parseInt(cl, 10) > 0 ? String(cl) : "";
  // SDK-faithful canonicalized headers: each line ends with a trailing newline.
  const canonicalHeaders =
    Object.keys(headers)
      .filter((h) => h.startsWith("x-ms-"))
      .sort()
      .map((h) => h + ":" + String(headers[h]).trimLeft() + "\n")
      .join("");
  const params = Object.keys(query)
    .map((k) => [k.toLowerCase(), decodeURIComponent(query[k])])
    .sort((a, b) => (a[0] < b[0] ? -1 : 1))
    .map((p) => "\n" + p[0] + ":" + p[1])
    .join("");
  const canonicalResource = "/" + backend.account + path + params;
  const stringToSign =
    [
      method,
      headers["content-language"] || "",
      headers["content-encoding"] || "",
      contentLength,
      headers["content-md5"] || "",
      headers["content-type"] || "",
      headers["date"] || "", // Date line stays empty when x-ms-date is used
      "", // If-Modified-Since
      "", // If-Match
      "", // If-None-Match
      "", // If-Unmodified-Since
      "", // If-Range
    ].join("\n") +
    "\n" +
    canonicalHeaders +
    canonicalResource;
  const sig = crypto
    .createHmac("sha256", Buffer.from(backend.key, "base64"))
    .update(stringToSign, "utf8")
    .digest("base64");
  return "SharedKey " + backend.account + ":" + sig;
}

function request(backend, opts) {
  const method = opts.method;
  const path = opts.path;
  const query = opts.query || {};
  const body = opts.body === undefined ? null : opts.body;
  return new Promise((resolve, reject) => {
    const h = { "x-ms-date": new Date().toUTCString(), "x-ms-version": VERSION };
    for (const k of Object.keys(opts.headers || {})) h[k.toLowerCase()] = opts.headers[k];
    if (opts.noVersion) delete h["x-ms-version"];
    let qs = "";
    const keys = Object.keys(query);
    if (keys.length) {
      qs = "?" + keys.map((k) => k + "=" + encodeURIComponent(query[k])).join("&");
    }
    if (opts.noContentLength) delete h["content-length"];
    else if (body) h["content-length"] = String(Buffer.byteLength(body));
    else h["content-length"] = "0";
    h["authorization"] = sign(backend, method, h, path, query);
    const lib = backend.endpoint.startsWith("https") ? https : http;
    const req = lib.request(
      backend.endpoint + path + qs,
      { method: method, headers: h, agent: backend.agent },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          resolve({
            status: res.statusCode,
            headers: res.headers,
            text: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

function parseError(text, headers) {
  let code = headers["x-ms-error-code"] || null;
  if (!code) {
    const c = text.match(/<Code>([\s\S]*?)<\/Code>/);
    if (c) code = c[1].trim();
  }
  const m = text.match(/<Message>([\s\S]*?)<\/Message>/);
  const message = m ? m[1].trim() : text.slice(0, 160) || null;
  return { code: code, message: message };
}

// Raw HTTP/1.1 over a socket (http for Azurite, TLS for smalt). Used for
// shapes node's http client cannot express: header names with invalid chars,
// genuinely absent Content-Length.
function rawRequest(backend, opts) {
  const method = opts.method;
  const pathQ = opts.pathQ;
  const headerLines = opts.headerLines; // array of pre-rendered "Name: value"
  const body = opts.body === undefined ? null : opts.body;
  const isTls = backend.endpoint.startsWith("https");
  const u = new URL(backend.endpoint);
  return new Promise((resolve, reject) => {
    const conn = isTls
      ? require_tls().connect({ host: "127.0.0.1", port: Number(u.port), rejectUnauthorized: false })
      : require_net().connect({ host: "127.0.0.1", port: Number(u.port) });
    let raw = "";
    conn.on("connect", () => {
      let req =
        method + " " + pathQ + " HTTP/1.1\r\n" +
        "Host: " + u.host + "\r\n" +
        headerLines.join("\r\n") + "\r\n" +
        "Connection: close\r\n\r\n";
      if (body) req += body;
      conn.write(req);
    });
    let buf = "";
    conn.on("data", (d) => (buf += d.toString("utf8")));
    conn.on("close", () => {
      const m = buf.match(/^HTTP\/1\.[01] (\d{3})/);
      resolve({
        status: m ? Number(m[1]) : 0,
        headers: {},
        text: buf.slice(buf.indexOf("\r\n\r\n") + 4),
      });
    });
    conn.on("error", reject);
  });
}
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
function require_tls() { return require("node:tls"); }
function require_net() { return require("node:net"); }

async function main() {
  const RUN = Date.now();
  const rows = [];
  const container = "w30d-" + RUN;

  // Setup leg: one known-good container + seed blob per backend.
  for (const b of BACKENDS) {
    let r = await request(b, {
      method: "PUT",
      path: "/" + b.account + "/" + container,
      query: { restype: "container" },
    });
    if (r.status !== 201) throw new Error(b.id + " setup container " + r.status + " " + r.text.slice(0, 200));
    r = await request(b, {
      method: "PUT",
      path: "/" + b.account + "/" + container + "/seed.txt",
      headers: { "x-ms-blob-type": "BlockBlob" },
      body: "0123456789",
    });
    if (r.status !== 201) throw new Error(b.id + " setup blob " + r.status + " " + r.text.slice(0, 200));
  }
  const seedC = container;

  const shapes = [
    {
      shape: "MissingXMsVersion",
      desc: "GET blob without x-ms-version header",
      method: "GET",
      url: "/{account}/" + seedC + "/seed.txt (no x-ms-version)",
      call: (b) =>
        request(b, {
          method: "GET",
          path: "/" + b.account + "/" + seedC + "/seed.txt",
          noVersion: true,
        }),
    },
    {
      shape: "ContainerNotFound",
      desc: "GET properties of a container that does not exist",
      method: "GET",
      url: "/{account}/no-such-container?restype=container",
      call: (b) =>
        request(b, {
          method: "GET",
          path: "/" + b.account + "/no-such-container",
          query: { restype: "container" },
        }),
    },
    {
      shape: "BlobNotFound",
      desc: "GET missing blob in an existing container",
      method: "GET",
      url: "/{account}/" + seedC + "/absent.txt",
      call: (b) => request(b, { method: "GET", path: "/" + b.account + "/" + seedC + "/absent.txt" }),
    },
    {
      shape: "ContainerAlreadyExists",
      desc: "PUT (create) a container that already exists",
      method: "PUT",
      url: "/{account}/" + seedC + "?restype=container",
      call: (b) =>
        request(b, {
          method: "PUT",
          path: "/" + b.account + "/" + seedC,
          query: { restype: "container" },
        }),
    },
    {
      shape: "InvalidRange",
      desc: "GET seed blob (10 bytes) with x-ms-range beyond length",
      method: "GET",
      url: "/{account}/" + seedC + "/seed.txt with x-ms-range: bytes=1000-2000",
      call: (b) =>
        request(b, {
          method: "GET",
          path: "/" + b.account + "/" + seedC + "/seed.txt",
          headers: { "x-ms-range": "bytes=1000-2000" },
        }),
    },
    {
      shape: "MissingContentLength",
      desc: "PUT block blob with empty Content-Length and no body",
      method: "PUT",
      url: "/{account}/" + seedC + "/nolen.txt (no Content-Length)",
      call: (b) =>
        rawRequest(b, {
          method: "PUT",
          pathQ: "/" + b.account + "/" + seedC + "/nolen.txt",
          headerLines: [
            "x-ms-date: " + new Date().toUTCString(),
            "x-ms-version: " + VERSION,
            "x-ms-blob-type: BlockBlob",
            "authorization: " + sign(b, "PUT", {
              "x-ms-date": new Date().toUTCString(),
              "x-ms-version": VERSION,
              "x-ms-blob-type": "BlockBlob",
            }, "/" + b.account + "/" + seedC + "/nolen.txt", {}),
          ],
        }),
    },
    {
      shape: "InvalidBlobOrBlock",
      desc: "PUT ?comp=blocklist referencing a block never PUT",
      method: "PUT",
      url: "/{account}/" + seedC + "/seed.txt?comp=blocklist",
      call: (b) =>
        request(b, {
          method: "PUT",
          path: "/" + b.account + "/" + seedC + "/seed.txt",
          query: { comp: "blocklist" },
          body:
            '<?xml version="1.0" encoding="utf-8"?><BlockList><Latest>block-never-put</Latest></BlockList>',
          headers: { "content-type": "application/xml" },
        }),
    },
    {
      shape: "InvalidQueryParameterValue",
      desc: "GET container with unknown comp value",
      method: "GET",
      url: "/{account}/" + seedC + "?restype=container&comp=bogus",
      call: (b) =>
        request(b, {
          method: "GET",
          path: "/" + b.account + "/" + seedC,
          query: { restype: "container", comp: "bogus" },
        }),
    },
    {
      shape: "MissingRequiredHeader",
      desc: "PUT blob without x-ms-blob-type",
      method: "PUT",
      url: "/{account}/" + seedC + "/nohint.txt (no x-ms-blob-type)",
      call: (b) =>
        request(b, {
          method: "PUT",
          path: "/" + b.account + "/" + seedC + "/nohint.txt",
          headers: {},
        }),
    },
    {
      shape: "InvalidMetadata",
      desc: "PUT blob with invalid metadata name (space + !)",
      method: "PUT",
      url: "/{account}/" + seedC + "/meta.txt with x-ms-meta-meta data!: v",
      call: (b) => {
        const h10 = {
          "x-ms-date": new Date().toUTCString(),
          "x-ms-version": VERSION,
          "x-ms-blob-type": "BlockBlob",
          "x-ms-meta-meta data!": "v",
        };
        return rawRequest(b, {
          method: "PUT",
          pathQ: "/" + b.account + "/" + seedC + "/meta.txt",
          headerLines: Object.keys(h10).map(
            (k) => k + ": " + h10[k]
          ).concat([
            "authorization: " + sign(b, "PUT", h10, "/" + b.account + "/" + seedC + "/meta.txt", {}),
          ]),
        });
      },
    },
  ];

  const results = { smalt: {}, azurite: {} };
  for (const b of BACKENDS) {
    for (const s of shapes) {
      let r;
      try {
        r = await s.call(b);
      } catch (e) {
        r = { status: 0, headers: {}, text: "TRANSPORT " + (e.message || e) };
      }
      const p = parseError(r.text, r.headers);
      results[b.id][s.shape] = { status: r.status, code: p.code, message: p.message };
    }
  }

  for (const s of shapes) {
    const a = results.smalt[s.shape];
    const z = results.azurite[s.shape];
    const verdict = a.status === z.status && a.code === z.code ? "MATCH" : "DIVERGE";
    rows.push({
      census: "W30-D",
      ts: new Date().toISOString(),
      shape: s.shape,
      method: s.method,
      url: s.url,
      smalt: a,
      azurite: z,
      verdict: verdict,
    });
  }

  for (const row of rows) fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
  console.log(
    rows
      .map(
        (r) =>
          r.shape +
          ": smalt=" + r.smalt.status + "/" + r.smalt.code +
          " azurite=" + r.azurite.status + "/" + r.azurite.code +
          " -> " + r.verdict,
      )
      .join("\n"),
  );
}

main().catch((e) => {
  console.error("FATAL " + (e.stack || e));
  process.exit(1);
});
