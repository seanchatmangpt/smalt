// recorded-test.mjs — W30-F replay half of the recorded-test pattern.
// Replays the recorded transactions against smalt WITHOUT any live recording
// pass: each recorded request is re-sent to the endpoint and the actual
// response is asserted equal to the recorded one (status, normalized headers,
// body). This is the guideline's test-double-as-infrastructure shape, with
// smalt playing the deterministic service under test.
//
// Usage: node recorded-test.mjs [endpoint]
//   The same clean-slate setup as the recorder runs first (unrecorded), so a
//   replay reproduces the recorded state machine exactly.
//
// Volatile headers (date, x-ms-request-id, etag, content-length, last-modified)
// are normalized away before comparison; everything else must match exactly.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const endpoint = process.argv[2] || "http://127.0.0.1:8443";
const recordingFile = join(here, "recordings", "blob-roundtrip.json");
const apiVersion = "2021-12-02";

const recording = JSON.parse(readFileSync(recordingFile, "utf8"));
if (recording.apiVersion !== apiVersion) {
  throw new Error(`api-version pin drift: recording=${recording.apiVersion} test=${apiVersion}`);
}

// Fresh container per replay run (standard recorded-test URL substitution):
// smalt HTTP-created containers default immutable=true (WORM) and deletes are
// 409-refused, so a recorded container can never be cleaned up between runs.
const runSuffix = `${Date.now()}-${process.pid}-${Math.floor(Math.random() * 1e6)}`;
const CONTAINER = `replay-pattern-${runSuffix}`;

const sts = process.env.SMALT_STS || "http://127.0.0.1:9443";
const token = await getToken(sts, "organizations");
const commonHeaders = { Authorization: `Bearer ${token}`, "x-ms-version": apiVersion };

// --- transport --------------------------------------------------------------
async function rawRequest(method, url, headers = {}, body = null) {
  const res = await fetch(url, { method, headers, body });
  const resHeaders = {};
  res.headers.forEach((v, k) => (resHeaders[k] = v));
  const resBody = Buffer.from(await res.arrayBuffer());
  return { status: res.status, headers: resHeaders, body: resBody };
}

async function getToken(stsBase, tenant) {
  const res = await fetch(`${stsBase}/${tenant}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body:
      "grant_type=client_credentials&client_id=recorder&client_secret=recorder-secret&scope=https://storage.azure.com/.default",
  });
  if (!res.ok) throw new Error(`STS ${res.status}: ${await res.text()}`);
  return (await res.json()).access_token;
}

// --- normalization ----------------------------------------------------------
const VOLATILE_HEADERS = new Set([
  "date",
  "x-ms-request-id",
  "etag",
  "content-length",
  "last-modified",
  "vary",
  "cache-control",
  "authorization",
]);

// Body normalization: smalt PUT-blob responses embed volatile etag/last_modified
// in the JSON body — strip those keys before comparison.
function normalizeBody(text) {
  try {
    const obj = JSON.parse(text);
    const strip = (o) => {
      if (Array.isArray(o)) return o.map(strip);
      if (o && typeof o === "object") {
        const out = {};
        for (const [k, v] of Object.entries(o)) if (!["etag", "last_modified"].includes(k)) out[k] = strip(v);
        return out;
      }
      return o;
    };
    return JSON.stringify(strip(obj));
  } catch {
    return text;
  }
}

function normalize(res) {
  const headers = {};
  for (const [k, v] of Object.entries(res.headers)) {
    if (!VOLATILE_HEADERS.has(k.toLowerCase())) headers[k.toLowerCase()] = v;
  }
  return { status: res.status, headers, body: normalizeBody(res.body.toString("utf8")) };
}

// --- clean slate (unrecorded setup, mirrors recorder.mjs) --------------------
const account = recording.account;
// Derive the recorded container name from the recording itself (URL
// substitution — the guideline's standard replay shape) and retarget every
// replayed request at a fresh per-run container.
const firstUrl = recording.transactions[0].request.url;
const m = firstUrl.match(new RegExp(`${account}/([^/?]+)`));
if (!m) throw new Error(`cannot derive container from ${firstUrl}`);
const recordedContainer = m[1];

// --- replay + assert ---------------------------------------------------------
let pass = 0;
const failures = [];

for (const tx of recording.transactions) {
  const recorded = {
    status: tx.response.status,
    headers: normalize(tx.response).headers,
    body: normalizeBody(tx.response.body),
  };
  // Re-issue the recorded request. The recorded Authorization header carries a
  // stale bearer from the recording session — substitute a fresh one so the
  // replay exercises the live token path without weakening the assertion.
  const headers = { ...tx.request.headers, Authorization: `Bearer ${token}` };
  const url = tx.request.url.replace(`/${recordedContainer}`, `/${CONTAINER}`);
  const bodyArg = tx.request.body === "" ? null : Buffer.from(tx.request.body);
  const actual = normalize(await rawRequest(tx.request.method, url, headers, bodyArg));

  const diffs = [];
  if (actual.status !== recorded.status) {
    diffs.push(`status recorded=${recorded.status} actual=${actual.status}`);
  }
  for (const [k, v] of Object.entries(recorded.headers)) {
    if (actual.headers[k] !== v) diffs.push(`header ${k}: recorded=${v} actual=${actual.headers[k]}`);
  }
  if (actual.body !== recorded.body) {
    diffs.push(`body: recorded=${JSON.stringify(recorded.body)} actual=${JSON.stringify(actual.body)}`);
  }

  if (diffs.length === 0) {
    pass++;
    console.log(`[replay] ${tx.name}: PASS (${actual.status})`);
  } else {
    failures.push({ name: tx.name, diffs });
    console.log(`[replay] ${tx.name}: FAIL\n  ${diffs.join("\n  ")}`);
  }
}

console.log(`\n[replay] ${pass}/${recording.transactions.length} transactions match recording`);
if (failures.length > 0) {
  process.exit(1);
}
