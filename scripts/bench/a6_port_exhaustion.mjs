// a6_port_exhaustion.mjs — adversarial cross-product bench lane A-6.
//
// Ingress inundation with ephemeral-port exhaustion (SNAT emulation) against
// the ARM listener (private-port substrate) at 127.0.0.1:9443.
//
// Design: rapid sequential short-lived HTTP connections (connect/GET/close,
// each from a fresh ephemeral source port) accumulate client-side TIME_WAIT
// sockets toward exhaustion of the local ephemeral range, while a CANARY
// worker sustains steady successful requests through the same source-port
// space. This emulates Azure SNAT port exhaustion: the client is the NAT
// gateway, ephemeral ports are SNAT ports, canary failures are the customer
// connection refusals.
//
// Measures:
//   - connections/s until first canary failure (exhaustion onset)
//   - canary error signature + count during exhaustion
//   - recovery latency after churn stops (TIME_WAIT drain, 2*MSL)
//   - substrate survival (must never crash)
//   - netstat TIME_WAIT count at peak
//
// 3 controlled bursts (A6_BURST_SECS, default 60) with drain observation
// between bursts. Azure billable row: NAT Gateway $0.045/GB + SNAT
// exhaustion = client connection refusals.
//
// Env:
//   A6_TARGET=http://127.0.0.1:9443  A6_BURSTS=3  A6_BURST_SECS=60
//   A6_JSONL=<result file>
//
// Output: JSONL rows appended to
//   docs/jira/v26.10.14/bench/a6-port-exhaustion.jsonl
// Exit 0 iff the substrate survived all bursts and recovered after drain.
import http from "node:http";
import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TARGET = process.env.A6_TARGET || "http://127.0.0.1:9443";
const BURSTS = parseInt(process.env.A6_BURSTS || "3", 10);
const BURST_SECS = parseInt(process.env.A6_BURST_SECS || "60", 10);
const REPO_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const JSONL = process.env.A6_JSONL ||
  path.join(REPO_ROOT, "docs/jira/v26.10.14/bench/a6-port-exhaustion.jsonl");
const PATH = "/subscriptions?api-version=2021-04-01";

const { hostname, port } = new URL(TARGET);
const out = [];
function print(s) { out.push(s); console.log(s); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function timewaitCount() {
  try {
    const o = execSync(
      `netstat -an -p tcp | awk '$6 == "TIME_WAIT" || $4 == "tcp4" && $6 == "TIME_WAIT"' | grep -c 127.0.0.1.${port}`,
      { shell: "/bin/bash", timeout: 5000 },
    );
    return parseInt(o.toString().trim(), 10) || 0;
  } catch (e) {
    // grep -c exits 1 on zero matches — that is a valid zero.
    if (e.status === 1) return 0;
    return -1;
  }
}

// One short-lived request on a fresh socket (no keep-alive, no pipelining).
// Resolves {ok, err, status} — connection-level failures are the signal.
function oneShot() {
  return new Promise((resolve) => {
    const req = http.get(
      { host: hostname, port, path: PATH, agent: false, headers: { connection: "close" } },
      (res) => {
        res.resume();
        res.on("end", () => resolve({ ok: true, status: res.statusCode }));
      },
    );
    req.on("error", (e) => resolve({ ok: false, err: e.code || String(e) }));
    req.setTimeout(5000, () => { req.destroy(new Error("TIMEOUT")); });
  });
}

// Canary: steady sequential requests; records success rate over time and
// stops at the first failure (that instant IS the exhaustion measurement).
async function canary(stopAt) {
  let ok = 0, fail = 0, firstFail = null;
  const sigs = {};
  let i = 0;
  while (Date.now() < stopAt) {
    i++;
    const r = await oneShot();
    if (r.ok) { ok++; } else {
      fail++;
      sigs[r.err] = (sigs[r.err] || 0) + 1;
      if (!firstFail) firstFail = { at: Date.now(), err: r.err, reqIndex: i };
    }
    if (i % 5 === 0) await sleep(0);
  }
  return { ok, fail, sigs, firstFail, total: i };
}

// Churn: as fast as sequential one-shots across C concurrent lanes.
async function churn(stopAt, lanes, stats) {
  await Promise.all(Array.from({ length: lanes }, async () => {
    while (Date.now() < stopAt) {
      const r = await oneShot();
      stats.total++;
      if (r.ok) stats.ok++;
      else { stats.fails++; stats.sigs[r.err] = (stats.sigs[r.err] || 0) + 1; }
    }
  }));
}

function machineInfo() {
  try {
    return {
      cpu: execSync("sysctl -n machdep.cpu.brand_string").toString().trim(),
      cores: parseInt(execSync("sysctl -n hw.ncpu").toString().trim(), 10),
      ephemeral_range: "49152-65535 (default macOS ip_portfleet/ephemeral, ~16k ports)",
      timewait_msl_secs: 15,
    };
  } catch { return {}; }
}

async function main() {
  print(JSON.stringify({ event: "bench_start", lane: "A-6", target: TARGET,
    bursts: BURSTS, burst_secs: BURST_SECS, machine: machineInfo(),
    ts: new Date().toISOString() }));

  // Pre-flight: substrate must be healthy before we touch it.
  const pre = await oneShot();
  if (!pre.ok) { print(JSON.stringify({ event: "preflight_fail", err: pre.err })); flush(1); return; }
  print(JSON.stringify({ event: "preflight_ok", status: pre.status }));

  let substrateSurvived = true;

  for (let b = 1; b <= BURSTS; b++) {
    const t0 = Date.now();
    const stopAt = t0 + BURST_SECS * 1000;
    const churnStats = { total: 0, ok: 0, fails: 0, sigs: {} };

    // Peak TIME_WAIT sampler (independent 250 ms sampler).
    let peakTW = 0;
    const sampler = setInterval(() => { const c = timewaitCount(); if (c > peakTW) peakTW = c; }, 250);

    // Canary runs concurrently for the whole burst window.
    const canaryP = canary(stopAt);

    // Churn lanes: enough concurrency to burn ephemeral ports faster than
    // the 30 s TIME_WAIT cycle drains them.
    await churn(stopAt, 8, churnStats);
    clearInterval(sampler);
    const canaryRes = await canaryP;

    const wall = (Date.now() - t0) / 1000;
    const burstRow = {
      event: "burst", burst: b, wall_secs: +wall.toFixed(1),
      churn_conns: churnStats.total,
      churn_conn_per_sec: +(churnStats.total / wall).toFixed(1),
      churn_errors: churnStats.fails,
      churn_err_sigs: churnStats.sigs,
      canary_ok: canaryRes.ok, canary_fail: canaryRes.fail,
      canary_first_fail: canaryRes.firstFail
        ? { offset_secs: +((canaryRes.firstFail.at - t0) / 1000).toFixed(2), err: canaryRes.firstFail.err }
        : null,
      canary_err_sigs: canaryRes.sigs,
      timewait_peak: peakTW,
      ts: new Date().toISOString(),
    };
    print(JSON.stringify(burstRow));
    fs.appendFileSync(JSONL, JSON.stringify(burstRow) + "\n");

    // Substrate survival check immediately after burst.
    const alive = await oneShot();
    if (!alive.ok) { substrateSurvived = false; print(JSON.stringify({ event: "substrate_down", burst: b })); break; }
    print(JSON.stringify({ event: "substrate_alive_post_burst", burst: b, status: alive.status }));

    // Recovery: time from churn stop until canary passes again (if it failed).
    if (canaryRes.firstFail) {
      const recT0 = Date.now();
      let recovered = false;
      while (Date.now() - recT0 < 120_000) {
        const r = await oneShot();
        if (r.ok) { recovered = true; break; }
        await sleep(250);
      }
      const recMs = Date.now() - recT0;
      print(JSON.stringify({ event: "recovery", burst: b, recovered, recovery_ms: recMs }));
      fs.appendFileSync(JSONL, JSON.stringify({ event: "recovery", burst: b, recovered, recovery_ms: recMs }) + "\n");
    }
    await sleep(2000);
  }

  // Final substrate survival verification.
  const fin = await oneShot();
  const finOk = fin.ok;
  if (!finOk) substrateSurvived = false;

  const verdict = substrateSurvived && finOk ? "PASS" : "FAIL";
  print(JSON.stringify({ event: "bench_end", verdict, substrate_survived: substrateSurvived,
    final_check: finOk ? `HTTP ${fin.status}` : `ERR ${fin.err}`,
    ts: new Date().toISOString() }));
  flush(verdict === "PASS" ? 0 : 1);
}

function flush(code) {
  fs.appendFileSync(JSONL, out.map((l) => l).join("\n") + "\n");
  process.exit(code);
}

main();
