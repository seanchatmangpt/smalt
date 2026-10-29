// SCVD-T2 lane: 128 concurrent Cosmos doc PUT/GET cycles against the LIVE substrate.
// Not a registry lane — emits only to tmp/bench/scvd-tier2.jsonl.
// Chicago-style: real HTTP collaborator, assert on returned body state.
// Typed FAIL (exit 1) on any error or wall > 30s. Loud SKIP (exit 3) if substrate down.
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const DATA = process.env.SCVD_DATA ?? "http://127.0.0.1:8443";
const ARM = process.env.SCVD_ARM ?? "http://127.0.0.1:9443";
const OUT = process.env.SCVD_OUT ?? new URL("../../tmp/bench/scvd-tier2.jsonl", import.meta.url).pathname;
const CONCURRENCY = Number(process.env.SCVD_CONCURRENCY ?? 128);
const CYCLES_PER_WORKER = Number(process.env.SCVD_CYCLES ?? 4);
const WALL_BUDGET_MS = 30_000;

const log = (...a) => console.log(new Date().toISOString(), ...a);

// ---- substrate liveness (loud SKIP, never restart) ------------------------
function probe(url, expect401 = false) {
  return new Promise((res) => {
    const req = http.get(url, { timeout: 5000 }, (r) => {
      r.resume();
      res(expect401 ? r.statusCode === 401 || r.statusCode < 500 : r.statusCode < 500);
    });
    req.on("timeout", () => { req.destroy(); res(false); });
    req.on("error", () => res(false));
  });
}
async function substrateUp() {
  const armOk = await probe(new URL("/providers?api-version=2099-01-01", ARM));
  const dataOk = await probe(new URL("/dbs", DATA), true);
  return armOk && dataOk;
}

// ---- bearer token from emulator STS ---------------------------------------
async function mintToken() {
  const body = "grant_type=client_credentials&client_id=scvd-t2&client_secret=scvd-t2";
  const r = await fetch(`${ARM}/organizations/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!r.ok) throw new Error(`STS mint failed: ${r.status}`);
  const j = await r.json();
  if (!j.access_token) throw new Error("STS mint: no access_token");
  return j.access_token;
}

// ---- minimal cosmos REST client (Bearer over the enforce-mode data plane) --
function req(method, urlPath, { pk, body, upsert } = {}, token) {
  return new Promise((resolve) => {
    const u = new URL(urlPath, DATA);
    const payload = body === undefined ? null : JSON.stringify(body);
    const headers = { authorization: `Bearer ${token}` };
    if (pk !== undefined) headers["x-ms-documentdb-partitionkey"] = JSON.stringify([pk]);
    if (upsert) headers["x-ms-documentdb-is-upsert"] = "true";
    if (payload !== null) {
      headers["content-type"] = "application/json";
      headers["content-length"] = Buffer.byteLength(payload);
    }
    const r = http.request(u, { method, headers, timeout: 30_000 }, (res) => {
      let buf = "";
      res.on("data", (c) => (buf += c));
      res.on("end", () => resolve({ status: res.statusCode, body: buf }));
    });
    r.on("timeout", () => { r.destroy(new Error("client-timeout")); });
    r.on("error", (e) => resolve({ status: 0, body: String(e.message) }));
    if (payload !== null) r.write(payload);
    r.end();
  });
}

function pct(sorted, p) {
  const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return Number(sorted[Math.max(0, i)].toFixed(3));
}
function emit(obj) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(obj) + "\n");
}

const machine = JSON.stringify({
  cpu: "Apple M3 Max", cores: 16, ram_gb: 48,
  elixir: "1.20.4-otp-29", otp: "29.1.2", darwin: "26.2",
});

// ---- main --------------------------------------------------------------------
if (!(await substrateUp())) {
  log("SKIP: live substrate down (9443/8443 not serving) — lane law: never restart");
  emit({
    lane: "scvd-tier2", surface: "cosmos-docs", op: "skip-substrate-down", n: 0,
    ops_per_sec: 0, p50_ms: 0, p95_ms: 0, p99_ms: 0, errors: 0,
    wall_ms: 0, machine, standing: "SKIP",
  });
  process.exit(3);
}

const token = await mintToken();
const db = `scvd-t2-${Date.now()}`;
const mk = await req("POST", "/dbs", { body: { id: db } }, token);
log("db create", mk.status, db);
const mkColl = await req("POST", `/dbs/${db}/colls`, { body: { id: "c1", partitionKey: { paths: ["/pk"] } } }, token);
log("coll create", mkColl.status);

const lat = [];
let errors = 0;
let ops = 0;
let lastErr = "";

const worker = async (w) => {
  for (let c = 0; c < CYCLES_PER_WORKER; c++) {
    const id = `t2-${w}-${c}`;
    const pk = `pk${w % 16}`;
    const doc = { id, pk, payload: crypto.randomBytes(256).toString("hex"), seq: c };
    const t0 = performance.now();
    const put = await req("POST", `/dbs/${db}/colls/c1/docs`, { pk, body: doc, upsert: true }, token);
    const putMs = performance.now() - t0;
    if (put.status !== 201 && put.status !== 200) {
      errors++; lastErr = `POST ${put.status} ${put.body.slice(0, 120)}`; lat.push(putMs); ops++; continue;
    }
    const t1 = performance.now();
    const get = await req("GET", `/dbs/${db}/colls/c1/docs/${id}`, { pk }, token);
    const getMs = performance.now() - t1;
    lat.push(putMs, getMs);
    ops += 2;
    const okGet = get.status === 200 && get.body.includes(`"id":"${id}"`);
    if (!okGet) { errors++; lastErr = `GET ${get.status} ${get.body.slice(0, 120)}`; }
  }
};

const t0 = Date.now();
await Promise.all(Array.from({ length: CONCURRENCY }, (_, w) => worker(w)));
const wallMs = Date.now() - t0;
const sorted = [...lat].sort((a, b) => a - b);
const p50 = pct(sorted, 50), p95 = pct(sorted, 95), p99 = pct(sorted, 99);
const opsPerSec = Number((ops / (wallMs / 1000)).toFixed(1));
const standing = errors === 0 && wallMs <= WALL_BUDGET_MS ? "PASS" : "FAIL";

emit({
  lane: "scvd-tier2", surface: "cosmos-docs", op: `putget-c${CONCURRENCY}`, n: ops,
  ops_per_sec: opsPerSec, p50_ms: p50, p95_ms: p95, p99_ms: p99,
  errors, wall_ms: wallMs, wall_budget_ms: WALL_BUDGET_MS,
  concurrency: CONCURRENCY, cycles_per_worker: CYCLES_PER_WORKER,
  machine, standing,
});
log(`n=${ops} ops/s=${opsPerSec} p50=${p50}ms p95=${p95}ms p99=${p99}ms errors=${errors} wall=${wallMs}ms standing=${standing}${lastErr ? " lastErr=" + lastErr : ""}`);
process.exit(standing === "PASS" ? 0 : 1);
