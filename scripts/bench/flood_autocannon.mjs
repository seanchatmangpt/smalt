// flood_autocannon.mjs — ERRC lane 3 (Eliminate): replicate scripts/stress/spike.py's
// burst pattern using autocannon's connection management instead of 500 hand-rolled
// client threads (the class that produced B-11's 21,027 client-side EADDRNOTAVAIL
// ephemeral-port exhaustion failures in TLS churn sc5).
//
// Pattern replicated (mirrors spike.py):
//   - N cycles, each = 500 concurrent connections x 5 ARM PUTs (2,500 reqs/cycle,
//     25,000 reqs over 10 cycles), connection-reuse-per-client kept (autocannon
//     default keep-alive, 1 socket per connection).
//   - Recovery probe after each cycle: single fresh-connection ARM PUT, budget < 100 ms.
//   - TLS herd: 100 parallel TLS handshakes + 1 GET each against the ARM TLS twin.
//
// Env:
//   FLOOD_ARM=http://127.0.0.1:39120   ARM front door
//   FLOOD_TLS=https://127.0.0.1:39124  ARM TLS twin
//   FLOOD_CYCLES=10  FLOOD_CONNS=500  FLOOD_REQS=5
//   FLOOD_TOKEN=anon                  bearer token (anonymous-auth substrate ignores)
//
// Output: per-cycle SUMMARY line + final JSON receipt to stdout; exit 0 iff all
// cycles returned zero 5xx and zero transport errors.
//
// NOTE: this is a load harness, not a bench lane — do not emit to bench/*.jsonl.
import { createRequire } from "node:module";
import fs from "node:fs";

const require = createRequire(new URL("../../test/sdk-full/package.json", import.meta.url));
const autocannon = require("autocannon");

const ARM = process.env.FLOOD_ARM || "http://127.0.0.1:39120";
const TLS = process.env.FLOOD_TLS || "https://127.0.0.1:39124";
const CYCLES = parseInt(process.env.FLOOD_CYCLES || "10", 10);
const CONNS = parseInt(process.env.FLOOD_CONNS || "500", 10);
const REQS = parseInt(process.env.FLOOD_REQS || "5", 10);
const TOKEN = process.env.FLOOD_TOKEN || "anon";

const SUB = "flood-sub";
const API = "2021-04-01";
const out = [];

function print(s) {
  out.push(s);
  console.log(s);
}

function runCycle(cycle) {
  return new Promise((resolve, reject) => {
    let done = false;
    const inst = autocannon(
      {
        url: ARM,
        method: "PUT",
        connections: CONNS,
        pipelining: 1, // 1 in-flight per socket — matches spike.py's 5 serial reqs per client
        amount: CONNS * REQS, // 2,500 requests, then stop (burst, not duration)
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${TOKEN}`,
        },
        body: JSON.stringify({ location: "flood" }),
        path: () => `/subscriptions/${SUB}/resourceGroups/rg-flood-${cycle}-${Math.floor(Math.random() * 1e9)}?api-version=${API}`,
        setupClient: (client) => {
          client.on("connError", (err) => {
            if (cycleErrs.length < 20) cycleErrs.push(`connError: ${String(err && err.message || err).slice(0, 200)}`);
          });
        },
        timeout: 20,
      },
      (err, result) => {
        if (done) return;
        done = true;
        if (err) return reject(err);
        resolve(result);
      },
    );
    inst.on("reqError", (err) => {
      if (cycleErrs.length < 20) cycleErrs.push(`reqError: ${String(err && err.message || err).slice(0, 200)}`);
    });
  });
}
// error sample accumulator for the current cycle
let cycleErrs = [];

function runTlsHerd() {
  return new Promise((resolve) => {
    let done = false;
    const inst = autocannon(
      {
        url: TLS,
        method: "GET",
        connections: 100,
        amount: 100, // one request per connection = 100 fresh TLS handshakes
        headers: { authorization: `Bearer ${TOKEN}` },
        path: "/subscriptions?api-version=2021-04-01",
        // unverified dev cert
        tlsOptions: { rejectUnauthorized: false },
        timeout: 20,
        excludeTotalDuration: true,
      },
      (err, result) => {
        if (done) return;
        done = true;
        if (err) return resolve(null);
        resolve(result);
      },
    );
    inst.on("reqError", () => {});
    inst.on("connError", () => {});
  });
}

async function recoveryProbe(token) {
  // single fresh-connection PUT, budget < 100 ms
  const t0 = performance.now();
  try {
    const res = await fetch(`${ARM}/subscriptions/${SUB}/resourceGroups/rg-recov-${Date.now()}?api-version=${API}`, {
      method: "PUT",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ location: "flood-recovery" }),
      signal: AbortSignal.timeout(10_000),
    });
    await res.arrayBuffer();
    return { ms: performance.now() - t0, status: res.status };
  } catch (e) {
    return { ms: performance.now() - t0, error: String(e && e.message || e).slice(0, 200) };
  }
}

function pct(v, p) {
  const s = [...v].sort((a, b) => a - b);
  return s[Math.round((p / 100) * (s.length - 1))];
}

const started = new Date().toISOString();
const cycles = [];
let totReq = 0, tot5xx = 0, totErr = 0, totRecovFail = 0;

for (let c = 1; c <= CYCLES; c++) {
  cycleErrs = [];
  const t0 = performance.now();
  const r = await runCycle(c);
  const wallS = (performance.now() - t0) / 1000;
  const statuses = r.statusCodeStats || {};
  const five_xx = Object.entries(statuses)
    .filter(([k]) => k.startsWith("5"))
    .reduce((a, [, v]) => a + v.count, 0);
  const errors = r.errors + r.timeouts + r.non2xx === 0 ? 0 : r.errors + r.timeouts;
  const recov = await recoveryProbe(TOKEN);
  const recovOk = !recov.error && recov.ms < 100;
  if (!recovOk) totRecovFail++;
  const row = {
    cycle: c,
    wall_s: +wallS.toFixed(3),
    requests: r.requests.total,
    req_per_s: +r.requests.average.toFixed(1),
    p50_ms: +r.latency.p50.toFixed(3),
    // autocannon histogram has no p95 key; p97_5 is the adjacent upper-bound bucket
    p95_ms: +(r.latency.p95 ?? r.latency.p97_5).toFixed(3),
    p97_5_ms: +r.latency.p97_5.toFixed(3),
    p99_ms: +r.latency.p99.toFixed(3),
    max_ms: +r.latency.max.toFixed(3),
    five_xx,
    errors: errors,
    error_samples: cycleErrs,
    status_counts: Object.fromEntries(Object.entries(statuses).map(([k, v]) => [k, v.count])),
    recovery_ms: recov.error ? null : +recov.ms.toFixed(3),
    recovery_ok: recovOk,
  };
  cycles.push(row);
  print(`SUMMARY cycle=${c} wall_s=${row.wall_s} reqs=${row.requests} rps=${row.req_per_s} p50=${row.p50_ms}ms p95=${row.p95_ms}ms p99=${row.p99_ms}ms 5xx=${five_xx} errors=${row.errors} recovery=${row.recovery_ms}ms ${recovOk ? "OK" : "FAIL"}`);
  totReq += row.requests;
  tot5xx += five_xx;
  totErr += row.errors;
  if (c < CYCLES) await new Promise((r2) => setTimeout(r2, 5000));
}

const tls = await runTlsHerd();
const tlsRow = tls
  ? {
      clients: 100,
      n: tls.requests.total,
      p50_ms: +tls.latency.p50.toFixed(3),
      p95_ms: +(tls.latency.p95 ?? tls.latency.p97_5).toFixed(3),
      p99_ms: +tls.latency.p99.toFixed(3),
      five_xx: Object.entries(tls.statusCodeStats || {})
        .filter(([k]) => k.startsWith("5"))
        .reduce((a, [, v]) => a + v.count, 0),
      errors: tls.errors + tls.timeouts,
    }
  : null;
if (tlsRow) {
  totReq += tlsRow.n;
  tot5xx += tlsRow.five_xx;
  totErr += tlsRow.errors;
  print(`SUMMARY tls_herd n=${tlsRow.n} p50=${tlsRow.p50_ms}ms p95=${tlsRow.p95_ms}ms p99=${tlsRow.p99_ms}ms 5xx=${tlsRow.five_xx} errors=${tlsRow.errors}`);
}

const pass = tot5xx === 0 && totErr === 0 && totRecovFail === 0;
print(`TOTALS requests=${totReq} 5xx=${tot5xx} transport_errors=${totErr} recovery_fails=${totRecovFail}`);
const receipt = {
  schema: "smalt-flood-autocannon/v1",
  generated_at: started,
  harness: "scripts/bench/flood_autocannon.mjs (autocannon " + (require("autocannon/package.json").version) + ")",
  config: { arm: ARM, tls: TLS, cycles: CYCLES, connections: CONNS, reqs_per_conn: REQS },
  cycles,
  tls_herd: tlsRow,
  totals: { requests: totReq, five_xx: tot5xx, transport_errors: totErr, recovery_fails: totRecovFail },
  verdict: pass ? "PASS" : "FAIL",
};
fs.mkdirSync("/Users/sac/smalt/tmp", { recursive: true });
fs.writeFileSync("/Users/sac/smalt/tmp/flood-autocannon-receipt.json", JSON.stringify(receipt, null, 2));
print(`RECEIPT tmp/flood-autocannon-receipt.json verdict=${receipt.verdict}`);
process.exit(pass ? 0 : 1);
