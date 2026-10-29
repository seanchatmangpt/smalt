// SCVD-T3: Cosmos doc create+GET ramp + Threshold Wall vs the LIVE substrate.
// Emits only tmp/bench/scvd-tier3.jsonl (harness lane, not a registry lane).
// Levels 512 -> 1024 -> 2048 concurrent workers; each worker runs CYCLES
// create+GET cycles against the data plane (enforce-mode Bearer from STS).
// Emulator contract (KD-pinned): create is POST to the docs resource; PUT on
// a doc is REPLACE (404 on a new id). GET body is asserted to contain the
// written id (Chicago: real collaborator, state assertion).
// Wall = first level with errors>0 OR p99 > 5x previous level's p99.
// Typed FAIL (exit 1) if the 512 level itself errors. SKIP (exit 3) if down.
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const DATA = process.env.SCVD_DATA ?? "http://127.0.0.1:8443";
const ARM = process.env.SCVD_ARM ?? "http://127.0.0.1:9443";
const OUT = process.env.SCVD_OUT ?? new URL("../../tmp/bench/scvd-tier3.jsonl", import.meta.url).pathname;
const LEVELS = (process.env.SCVD_LEVELS ?? "512,1024,2048")
  .split(",").map(Number).filter(Boolean);
const CYCLES_PER_WORKER = Number(process.env.SCVD_CYCLES ?? 4);

const log = (...a) => console.log(new Date().toISOString(), ...a);

// ---- substrate liveness (loud SKIP, never restart) -------------------------
function probe(url, expect401) {
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
  const armOk = await probe(new URL("/providers?api-version=2099-01-01", ARM), false);
  const dataOk = await probe(new URL("/dbs", DATA), true);
  return armOk && dataOk;
}

// ---- bearer token from emulator STS ----------------------------------------
async function mintToken() {
  const res = await fetch(`${ARM}/organizations/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=scvd-t3&client_secret=scvd-t3",
  });
  if (!res.ok) throw new Error(`STS mint failed: ${res.status}`);
  const j = await res.json();
  if (!j.access_token) throw new Error("STS mint: no access_token");
  return j.access_token;
}

// ---- minimal cosmos REST client (Bearer over the enforce data plane) -------
function req(method, urlPath, opts, token) {
  const { pk, body } = opts || {};
  return new Promise((resolve) => {
    const u = new URL(urlPath, DATA);
    const payload = body === undefined ? null : JSON.stringify(body);
    const headers = { authorization: "Bearer " + token };
    if (pk !== undefined) headers["x-ms-documentdb-partitionkey"] = JSON.stringify([pk]);
    if (payload !== null) {
      headers["content-type"] = "application/json";
      headers["content-length"] = Buffer.byteLength(payload);
    }
    const r = http.request(u, { method, headers, timeout: 30000 }, (res) => {
      let buf = "";
      res.on("data", (c) => { buf += c; });
      res.on("end", () => resolve({ status: res.statusCode, body: buf }));
    });
    r.on("timeout", () => { r.destroy(new Error("client-timeout")); });
    r.on("error", (e) => resolve({ status: 0, body: String(e.message) }));
    if (payload !== null) r.write(payload);
    r.end();
  });
}

// ---- machine spec + jsonl emission ------------------------------------------
function machineSpec() {
  return JSON.stringify({
    cpu: "Apple M3 Max", cores: 16, ram_gb: 48,
    elixir: "1.20.4-otp-29", otp: "29.1.2", darwin: "26.2",
  });
}
function emit(obj) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(obj) + "\n");
}
function pct(sorted, p) {
  const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return Number(sorted[Math.max(0, i)].toFixed(3));
}

// ---- one ramp level ---------------------------------------------------------
async function runLevel(level, token, db, coll) {
  const lat = [];
  let errors = 0;
  let ops = 0;
  let lastErr = "";
  const worker = async (w) => {
    for (let c = 0; c < CYCLES_PER_WORKER; c++) {
      const id = "t3-" + level + "-" + w + "-" + c;
      const pk = "pk" + (w % 16);
      const doc = { id: id, pk: pk, payload: crypto.randomBytes(256).toString("hex"), seq: c };
      const t0 = performance.now();
      const put = await req("POST", "/dbs/" + db + "/colls/" + coll + "/docs", { pk: pk, body: doc }, token);
      const putMs = performance.now() - t0;
      lat.push(putMs); ops++;
      if (put.status !== 201 && put.status !== 200) {
        errors++;
        lastErr = "CREATE " + put.status + " " + put.body.slice(0, 120);
        continue;
      }
      const t1 = performance.now();
      const get = await req("GET", "/dbs/" + db + "/colls/" + coll + "/docs/" + id, { pk: pk }, token);
      const getMs = performance.now() - t1;
      lat.push(getMs); ops++;
      const okGet = get.status === 200 && get.body.indexOf('"id":"' + id + '"') !== -1;
      if (!okGet) {
        errors++;
        lastErr = "GET " + get.status + " " + get.body.slice(0, 120);
      }
    }
  };
  const t0 = Date.now();
  await Promise.all(Array.from({ length: level }, (_, w) => worker(w)));
  const wallMs = Date.now() - t0;
  const sorted = lat.slice().sort((a, b) => a - b);
  return {
    level: level, n: ops, ops_per_sec: Number((ops / (wallMs / 1000)).toFixed(1)),
    p50: pct(sorted, 50), p95: pct(sorted, 95), p99: pct(sorted, 99),
    errors: errors, lastErr: lastErr,
  };
}

// ---- main --------------------------------------------------------------------
async function main() {
  const t0 = Date.now();
  if (!(await substrateUp())) {
    log("SKIP: live substrate down (9443/8443 not serving) — lane law: never restart");
    emit({
      lane: "scvd-tier3", surface: "cosmos-docs", op: "ramp-skip", n: 0,
      ops_per_sec: 0, p50_ms: 0, p95_ms: 0, p99_ms: 0, errors: 0,
      wall_level: "SKIP-substrate-down", machine: machineSpec(),
    });
    process.exit(3);
  }

  const token = await mintToken();
  const db = "scvd-t3-" + Date.now();
  const mkDb = await req("POST", "/dbs", { body: { id: db } }, token);
  log("db create", mkDb.status, db);
  const mkColl = await req("POST", "/dbs/" + db + "/colls", { body: { id: "c1", partitionKey: { paths: ["/pk"] } } }, token);
  log("coll create", mkColl.status);

  let prevP99 = null;
  let wallLevel = "unreached";
  let typedFail = false;
  for (const level of LEVELS) {
    const r = await runLevel(level, token, db, "c1");
    const degraded = prevP99 !== null && r.p99 > 5 * prevP99;
    const failed = r.errors > 0 || degraded;
    emit({
      lane: "scvd-tier3", surface: "cosmos-docs", op: "ramp-" + level, n: r.n,
      ops_per_sec: r.ops_per_sec, p50_ms: r.p50, p95_ms: r.p95, p99_ms: r.p99,
      errors: r.errors, wall_level: wallLevel, machine: machineSpec(),
    });
    log("level " + level + ": n=" + r.n + " ops/s=" + r.ops_per_sec +
        " p50=" + r.p50 + "ms p95=" + r.p95 + "ms p99=" + r.p99 + "ms" +
        " errors=" + r.errors + " degraded=" + degraded +
        (r.lastErr ? " lastErr=" + r.lastErr : ""));
    if (failed) {
      wallLevel = "L" + level;
      if (level === LEVELS[0] && r.errors > 0) typedFail = true;
      break;
    }
    prevP99 = r.p99;
  }

  emit({
    lane: "scvd-tier3", surface: "cosmos-docs", op: "wall-summary", n: 0,
    ops_per_sec: 0, p50_ms: 0, p95_ms: 0, p99_ms: 0, errors: 0,
    wall_level: wallLevel, typed_fail_512: typedFail, machine: machineSpec(),
  });
  log("WALL=" + wallLevel + " typedFail512=" + typedFail + " totalMs=" + (Date.now() - t0));
  process.exit(typedFail ? 1 : 0);
}

main();
