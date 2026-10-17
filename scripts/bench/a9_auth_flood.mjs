const HERE = path.dirname(import.meta.url).replace("file://", "");
// a9_auth_flood.mjs — adversarial cross-product bench lane A-9.
//
// Cross-tenant auth challenge flood against an ENFORCE-mode substrate:
// high-frequency tokenless requests (each answered 401 with the KD-15/S-3
// enriched `WWW-Authenticate: Bearer authorization=..., resource=...`
// challenge — a per-request string build) interleaved with valid signed
// tokens across 10 virtual tenant ids.
//
// Phases:
//   1. CHALLENGE FLOOD   — tokenless GET /subscriptions?api-version=2021-04-01
//      at max rate; each response carries the enriched challenge.
//   2. TOKEN-ATTACH 50/50 — two concurrent autocannon instances: half the
//      connections tokenless (401), half carrying valid HS256 tokens minted
//      from the STS endpoint across 10 virtual tenant ids (200). The
//      200-rate delta vs the all-valid baseline isolates the
//      challenge-serialization overhead.
//   3. BASELINE — all-valid reads only (B-2-class ARM reads reference).
//   4. MEMORY — substrate beam RSS sampled every 250 ms during the flood;
//      verdict: per-request-and-collected (flat/plateau under GC) vs
//      accumulating (monotone climb).
//
// Env:
//   A9_ARM=http://127.0.0.1:39490   ARM front door (enforce substrate)
//   A9_FLOOD_N=20000  A9_MIXED_N=10000  A9_BASELINE_N=10000
//   A9_CONNS=100  A9_TENANTS=10  A9_RSS_PID=<beam pid>
//   A9_JSONL=<result file>
//
// Output: JSONL rows appended to the lane result file
// (docs/jira/v26.10.14/bench/a9-auth-flood.jsonl) plus a companion RSS series
// file (a9-auth-flood-rss.jsonl). Exit 0 iff the flood leg is 100% 401, the
// mixed leg produced both 401s and 200s, and no unexpected statuses appeared.
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const require = createRequire(new URL("../../test/sdk-full/package.json", import.meta.url));
const autocannon = require("autocannon");

const ARM = process.env.A9_ARM || "http://127.0.0.1:39490";
const FLOOD_N = parseInt(process.env.A9_FLOOD_N || "20000", 10);
const MIXED_N = parseInt(process.env.A9_MIXED_N || "10000", 10);
const BASELINE_N = parseInt(process.env.A9_BASELINE_N || "10000", 10);
const CONNS = parseInt(process.env.A9_CONNS || "100", 10);
const TENANTS = parseInt(process.env.A9_TENANTS || "10", 10);
const RSS_PID = process.env.A9_RSS_PID || "";
const JSONL = process.env.A9_JSONL ||
  path.resolve(HERE, "../../docs/jira/v26.10.14/bench/a9-auth-flood.jsonl");
const RSS_LOG = JSONL.replace(/\.jsonl$/, "-rss.jsonl");
const API = "2021-04-01";

const out = [];
function print(s) { out.push(s); console.log(s); }

function benchMachine() {
  const sh = (c) => execSync(c).toString().trim();
  return {
    cpu: sh("sysctl -n machdep.cpu.brand_string"),
    cores: sh("sysctl -n hw.ncpu"),
    ram_gb: Math.round(parseInt(sh("sysctl -n hw.memsize")) / 1024 ** 3),
    elixir: sh("elixir -e 'IO.puts System.version()'"),
    otp: sh("elixir -e 'IO.puts :erlang.system_info(:otp_release)'"),
    darwin: sh("sw_vers -productVersion"),
  };
}

// --- RSS sampler ---------------------------------------------------------------
function rssKb(pid) {
  try {
    return parseInt(execSync(`ps -o rss= -p ${pid}`).toString().trim(), 10);
  } catch {
    return null;
  }
}

function sampleDuring(label, promise) {
  const vals = [];
  const t = setInterval(() => {
    const kb = RSS_PID ? rssKb(RSS_PID) : null;
    if (kb !== null) vals.push(kb);
  }, 250);
  return promise.finally(() => {
    clearInterval(t);
    if (vals.length) {
      const min = Math.min(...vals);
      const max = Math.max(...vals);
      print(`[RSS ${label}] n=${vals.length} first=${vals[0]}KB last=${vals[vals.length - 1]}KB ` +
        `min=${min}KB max=${max}KB climb=${max - vals[0]}KB`);
      fs.appendFileSync(RSS_LOG, JSON.stringify({
        phase: label, sample_ms: 250, n: vals.length,
        first_kb: vals[0], last_kb: vals[vals.length - 1],
        min_kb: min, max_kb: max, series_kb: vals,
      }) + "\n");
    }
  });
}

// --- autocannon wrapper ----------------------------------------------------------
function run(opts) {
  return new Promise((resolve, reject) => {
    autocannon(opts, (err, result) => (err ? reject(err) : resolve(result)));
  });
}

// autocannon's latency histogram exposes p50/p90/p97/p99 but not p95; when
// p95 is absent we carry p97 in the p95 field AND set p97_is_p95:true so the
// substitution is explicit, never silent.
function lats(res) {
  const l = res.latency || {};
  const hasP95 = l.p95 != null;
  return {
    p50: l.p50, p95: hasP95 ? l.p95 : (l.p97_5 != null ? l.p97_5 : l.p97), p99: l.p99,
    p97_is_p95: !hasP95,
  };
}

function statuses(result) {
  const m = {};
  const s = result.statusCodeStats || {};
  if (Array.isArray(s)) {
    for (const e of s) m[e.code] = e.count;
  } else {
    for (const [code, st] of Object.entries(s)) m[code] = st.count;
  }
  return m;
}

function check(name, res, expected) {
  const m = statuses(res);
  const ok = Object.keys(m).every((c) => expected.includes(Number(c)));
  if (!ok) print(`[CHECK] ${name}: UNEXPECTED statuses ${JSON.stringify(m)} (expected only ${expected})`);
  return { m, ok };
}

function emit(obj) {
  fs.appendFileSync(JSONL, JSON.stringify(obj) + "\n");
}

// --- token mint across virtual tenants -------------------------------------------
const tenantId = (i) =>
  `11111111-0000-0000-0000-${String(i).padStart(12, "0")}`;

async function mintTokens() {
  const tokens = [];
  for (let i = 0; i < TENANTS; i++) {
    const body = new URLSearchParams({
      grant_type: "client_credentials",
      client_id: `a9-client-${i}`,
      client_secret: "a9-secret",
    });
    const r = await fetch(`${ARM}/${tenantId(i)}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    if (!r.ok) throw new Error(`mint tenant ${i}: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
    tokens.push((await r.json()).access_token);
  }
  return tokens;
}

// --- phases ------------------------------------------------------------------------
async function phaseFlood() {
  print(`[PHASE 1] challenge flood: ${FLOOD_N} tokenless GET /subscriptions (enriched 401 challenge each)`);
  const res = await sampleDuring("flood", run({
    url: `${ARM}/subscriptions?api-version=${API}`,
    method: "GET",
    connections: CONNS,
    pipelining: 1,
    amount: FLOOD_N,
    timeout: 20,
  }));
  const { m, ok } = check("flood", res, [401]);
  const challenges = m[401] || 0;
  const L = lats(res);
  const cps = challenges / (res.duration || 1);
  print(`[FLOOD] requests=${res.requests.total} 401s=${challenges} duration=${res.duration}s ` +
    `challenges/s=${cps.toFixed(0)} p50=${L.p50}ms p95=${L.p95}ms${L.p97_is_p95 ? " (p97)" : ""} ` +
    `p99=${L.p99}ms transport_errors=${res.errors}`);
  emit({
    lane: "a9", surface: "arm-auth-enforce", op: "challenge-flood-tokenless-401",
    n: res.requests.total, ops_per_sec: Number(cps.toFixed(1)),
    p50_ms: L.p50, p95_ms: L.p95, p97_is_p95: L.p97_is_p95, p99_ms: L.p99,
    errors: (res.errors || 0) + (res.timeouts || 0),
    statuses: m, machine: benchMachine(), rss_series: RSS_LOG,
  });
  return ok && challenges === res.requests.total;
}

const mkOpts = (extra) => ({
  url: `${ARM}/subscriptions?api-version=${API}`,
  method: "GET",
  pipelining: 1,
  timeout: 20,
  ...extra,
});

// One virtual tenant per connection: setupClient runs once per connection at
// start, so a plain counter spreads the 10 tenant tokens round-robin.
const tenantPerConn = (tokens) => {
  let i = 0;
  return (client) => {
    const tok = tokens[i % tokens.length];
    i += 1;
    client.setHeaders({ authorization: `Bearer ${tok}` });
  };
};

async function phaseMixed(tokens) {
  const half = Math.max(1, Math.floor(CONNS / 2));
  print(`[PHASE 2] token-attach 50/50: ${MIXED_N} tokenless + ${MIXED_N} valid-signed ` +
    `(${half}+${half} connections, ${tokens.length} virtual tenants)`);
  const p401 = run(mkOpts({ connections: half, amount: MIXED_N }));
  const p200 = run(mkOpts({
    connections: half,
    amount: MIXED_N,
    setupClient: tenantPerConn(tokens),
  }));
  const [res401, res200] = await Promise.all([
    sampleDuring("mixed-401-leg", p401),
    sampleDuring("mixed-200-leg", p200),
  ]);
  const m401 = statuses(res401), m200 = statuses(res200);
  const c401 = m401[401] || 0, c200 = m200[200] || 0;
  const mixedRps = (c401 + c200) / ((res401.duration + res200.duration) / 2 || 1);
  print(`[MIXED] 401-leg=${c401} (dur ${res401.duration}s, ${(c401 / res401.duration).toFixed(0)}/s) ` +
    `200-leg=${c200} (dur ${res200.duration}s, ${(c200 / res200.duration).toFixed(0)}/s) ` +
    `mixed_total=${c401 + c200} mixed/s=${mixedRps.toFixed(0)} ` +
    `p50(401)=${res401.latency.p50}ms p99(401)=${res401.latency.p99}ms ` +
    `p50(200)=${res200.latency.p50}ms p99(200)=${res200.latency.p99}ms`);
  emit({
    lane: "a9", surface: "arm-auth-enforce", op: "token-attach-5050",
    n: c401 + c200,
    ops_per_sec: Number(mixedRps.toFixed(1)),
    p50_ms: res200.latency.p50, p95_ms: lats(res200).p95, p97_is_p95: lats(res200).p97_is_p95, p99_ms: res200.latency.p99,
    errors: (res401.errors || 0) + (res401.timeouts || 0) + (res200.errors || 0) + (res200.timeouts || 0),
    statuses_401_leg: m401, statuses_200_leg: m200,
    machine: benchMachine(),
  });
  return c401 === MIXED_N && c200 === MIXED_N &&
    Object.keys({ ...m401, ...m200 }).every((c) => ["200", "401"].includes(c));
}

async function phaseBaseline(tokens) {
  print(`[PHASE 3] all-valid baseline: ${BASELINE_N} signed reads (B-2-class ARM reads reference)`);
  const res = await sampleDuring("baseline", run(mkOpts({
    connections: CONNS,
    amount: BASELINE_N,
    setupClient: tenantPerConn(tokens),
  })));
  const { m, ok } = check("baseline", res, [200]);
  const c200 = m[200] || 0;
  const rps = c200 / (res.duration || 1);
  print(`[BASELINE] requests=${res.requests.total} 200s=${c200} duration=${res.duration}s ` +
    `reads/s=${rps.toFixed(0)} p50=${res.latency.p50}ms p95=${lats(res).p95}ms${lats(res).p97_is_p95 ? " (p97)" : ""} p99=${res.latency.p99}ms`);
  emit({
    lane: "a9", surface: "arm-auth-enforce", op: "all-valid-signed-reads-baseline",
    n: res.requests.total, ops_per_sec: Number(rps.toFixed(1)),
    p50_ms: res.latency.p50, p95_ms: lats(res).p95, p97_is_p95: lats(res).p97_is_p95, p99_ms: res.latency.p99,
    errors: (res.errors || 0) + (res.timeouts || 0),
    statuses: m, machine: benchMachine(),
  });
  return ok && c200 === res.requests.total;
}

// --- main ----------------------------------------------------------------------------
let machine;
try {
  machine = benchMachine();
  print(`[MACHINE] ${JSON.stringify(machine)}`);
  print(`[SETUP] arm=${ARM} conns=${CONNS} tenants=${TENANTS} rss_pid=${RSS_PID || "none"}`);

  const tokens = await mintTokens();
  print(`[STS] minted ${tokens.length} tokens across ${TENANTS} virtual tenant ids`);

  const okFlood = await phaseFlood();
  const okMixed = await phaseMixed(tokens);
  const okBase = await phaseBaseline(tokens);

  // Phase 4 — sustained flood for the memory witness: fixed 20 s tokenless
  // flood at max rate with RSS sampled every 250 ms across the whole window.
  const SUSTAIN_S = parseInt(process.env.A9_SUSTAIN_S || "20", 10);
  print(`[PHASE 4] sustained challenge flood: ${SUSTAIN_S}s duration (memory witness)`);
  const sus = await sampleDuring("sustained-flood", run(mkOpts({
    connections: CONNS,
    duration: SUSTAIN_S,
  })));
  const susM = statuses(sus);
  const susC = susM[401] || 0;
  const susL = lats(sus);
  print(`[SUSTAINED] requests=${sus.requests.total} 401s=${susC} ` +
    `challenges/s=${(susC / (sus.duration || 1)).toFixed(0)} ` +
    `p50=${susL.p50}ms p95=${susL.p95}ms${susL.p97_is_p95 ? " (p97)" : ""} p99=${susL.p99}ms`);
  emit({
    lane: "a9", surface: "arm-auth-enforce", op: "sustained-challenge-flood-20s",
    n: sus.requests.total, ops_per_sec: Number((susC / (sus.duration || 1)).toFixed(1)),
    p50_ms: susL.p50, p95_ms: susL.p95, p97_is_p95: susL.p97_is_p95, p99_ms: susL.p99,
    errors: (sus.errors || 0) + (sus.timeouts || 0),
    statuses: susM, machine: benchMachine(), rss_series: RSS_LOG,
  });
  const okSus = susC === sus.requests.total && (sus.errors || 0) === 0;

  const total = FLOOD_N + MIXED_N * 2 + BASELINE_N + sus.requests.total;
  print(`[TOTAL] requests executed = ${total}`);
  const pass = okFlood && okMixed && okBase && okSus;
  print(`[VERDICT] ${pass ? "PASS" : "FAIL"} ` +
    `(flood=${okFlood} mixed=${okMixed} baseline=${okBase} sustained=${okSus})`);
  process.exitCode = pass ? 0 : 1;
} catch (err) {
  print(`[FATAL] ${err && err.stack || err}`);
  process.exitCode = 1;
}
