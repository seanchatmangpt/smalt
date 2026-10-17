// n2_action_storm.mjs — lane N-2: server-action storm against the Next.js 16
// workspace production server (next start).
//
// Drive: 2,000 concurrent virtual users POSTing multipart/form-data
// server-action payloads (progressive-enhancement path: POST to the page URL
// with the $ACTION_ID_<id> hidden field so Next routes the POST to the action
// without the flight protocol; Next 16 does NOT support urlencoded action
// bodies — the action handler bails on application/x-www-form-urlencoded).
// Workload mix per global atomic counter:
//   - idx % 20 === 0            -> invalid payload (bad sku) — must be rejected
//   - idx % 50 === 7            -> double submission (two identical POSTs raced)
//   - otherwise                 -> valid unique submission
//
// Assertions (falsifiers):
//   F1 session leak: every accepted response echoes a fresh n2_rid via
//      set-cookie; a rid seen twice => cross-request state pollution => FAIL.
//   F2 rejection: every invalid payload must come back n2_verdict=rejected
//      (100% rejection rate) => else FAIL.
//   F3 latency: action p99 > 350 ms => FAIL.
//
// Event-loop delay is polled each second from /bench/metrics (same process,
// perf_hooks.monitorEventLoopDelay, per-interval windows via reset=1).
//
// Env:
//   N2_BASE (default http://127.0.0.1:4620)
//   N2_VUS (default 2000)  N2_ITERS (default 25 per VU)
//   N2_OUT (output JSONL path; empty => stdout only)
//
// Exit 0 iff F1/F2/F3 all pass.
import fs from "node:fs";
import http from "node:http";
import os from "node:os";

const BASE = process.env.N2_BASE || "http://127.0.0.1:4620";
const VUS = parseInt(process.env.N2_VUS || "2000", 10);
const ITERS = parseInt(process.env.N2_ITERS || "25", 10);
const OUT = process.env.N2_OUT || "";
// Progressive-enhancement action routing: hidden form field
// $ACTION_ID_<actionId> (what a no-JS browser form submit sends).
const ACTION_FIELD = `$ACTION_ID_${process.env.N2_ACTION_ID || ""}`;

const { hostname, port } = new URL(BASE);

// 2,000 keep-alive sockets: 1 socket per VU, no ephemeral-port churn.
const agent = new http.Agent({ keepAlive: true, maxSockets: VUS + 200, maxFreeSockets: 512 });

const latencies = [];
const ridSeen = new Set();
let accepted = 0, rejected = 0, validBounced = 0, transportErr = 0, unexpectedStatus = 0;
const transportCodes = {};
let sessionLeaks = 0, doubleSubmissionPairs = 0;

const nowMs = () => Number(process.hrtime.bigint() / 1000n) / 1000;

function hex(n) {
  let s = "";
  for (let i = 0; i < n; i++) s += Math.floor(Math.random() * 16).toString(16);
  return s;
}

function skuOk() {
  const L = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  let s = "";
  for (let i = 0; i < 3; i++) s += L[Math.floor(Math.random() * L.length)];
  return `${s}-${String(1000 + Math.floor(Math.random() * 9000))}`;
}

const BOUNDARY = "n2storm" + hex(16);

function multipartBody(fields) {
  const parts = [];
  const push = (name, value) => {
    parts.push(
      Buffer.from(
        `--${BOUNDARY}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`,
      ),
    );
  };
  for (const [k, v] of Object.entries(fields)) push(k, v);
  push(ACTION_FIELD, "");
  parts.push(Buffer.from(`--${BOUNDARY}--\r\n`));
  return Buffer.concat(parts);
}

function post(fields) {
  return new Promise((resolve) => {
    const body = multipartBody(fields);
    const req = http.request(
      {
        hostname, port, path: "/bench/action", method: "POST", agent,
        headers: {
          "content-type": `multipart/form-data; boundary=${BOUNDARY}`,
          "content-length": body.length,
        },
      },
      (res) => {
        const cookies = res.headers["set-cookie"] || [];
        const pick = (name) => {
          for (const c of cookies) {
            const m = c.match(new RegExp(`^${name}=([^;]+)`));
            if (m) return m[1];
          }
          return null;
        };
        res.resume();
        res.on("end", () => resolve({
          status: res.statusCode,
          rid: pick("n2_rid"),
          verdict: pick("n2_verdict"),
          reason: pick("n2_reject_reason"),
        }));
      },
    );
    req.on("error", (e) => resolve({ status: 0, code: e.code }));
    req.end(body);
  });
}

function metricsPoll() {
  return new Promise((resolve) => {
    const req = http.get({ hostname, port, path: "/bench/metrics?reset=1", agent }, (res) => {
      let buf = "";
      res.on("data", (d) => (buf += d));
      res.on("end", () => {
        try { resolve(JSON.parse(buf)); } catch { resolve(null); }
      });
    });
    req.on("error", () => resolve(null));
  });
}

function percentile(sorted, p) {
  if (!sorted.length) return 0;
  return sorted[Math.max(0, Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1))];
}

function accountAccepted(r, dt) {
  accepted++;
  latencies.push(dt);
  if (!r.rid) {
    // Accepted payload that failed to echo its request id: context loss.
    sessionLeaks++;
  } else if (ridSeen.has(r.rid)) {
    sessionLeaks++;
  } else {
    ridSeen.add(r.rid);
  }
}

let counter = 0;

async function vuLoop(vu) {
  for (let iter = 0; iter < ITERS; iter++) {
    const idx = counter++;
    const token = hex(16);
    const fields = { name: `bench-${vu}-${iter}`, qty: "7", sku: skuOk(), clientToken: token };
    if (idx % 20 === 0) { fields.sku = "bad-sku"; }

    if (idx % 50 === 7) {
      // Double submission: two identical valid POSTs raced concurrently.
      doubleSubmissionPairs++;
      const started = nowMs();
      const [a, b] = await Promise.all([post(fields), post(fields)]);
      const dt = nowMs() - started;
      for (const r of [a, b]) {
        if (r.status === 0) { transportErr++; transportCodes[r.code] = (transportCodes[r.code] || 0) + 1; continue; }
        if (r.status !== 200 && r.status !== 303) { unexpectedStatus++; continue; }
        if (r.verdict === "rejected") { validBounced++; continue; }
        accountAccepted(r, dt);
      }
      continue;
    }

    const invalid = idx % 20 === 0;
    const started = nowMs();
    const r = await post(fields);
    const dt = nowMs() - started;

    if (r.status === 0) { transportErr++; transportCodes[r.code] = (transportCodes[r.code] || 0) + 1; continue; }
    if (r.status !== 200 && r.status !== 303) { unexpectedStatus++; continue; }

    if (invalid) {
      if (r.verdict === "rejected") rejected++;
      else validBounced++; // invalid payload accepted => misroute
      continue;
    }
    if (r.verdict === "rejected") { validBounced++; continue; }
    accountAccepted(r, dt);
  }
}

const eldSamples = [];
let stopPolling = false;
async function pollLoop() {
  while (!stopPolling) {
    const m = await metricsPoll();
    if (m) eldSamples.push(m);
    await new Promise((r) => setTimeout(r, 1000));
  }
}

// Warmup: 200 valid posts at modest concurrency (JIT/route compile).
const warmupStart = Date.now();
await Promise.all(
  Array.from({ length: 200 }, () =>
    post({ name: "warmup", qty: "7", sku: skuOk(), clientToken: hex(16) }),
  ),
);
const warmupMs = Date.now() - warmupStart;
ridSeen.clear(); // warmup rids are not part of the leak falsifier
latencies.length = 0;

const poll = pollLoop();
const stormStart = Date.now();
await Promise.all(Array.from({ length: VUS }, (_, vu) => vuLoop(vu)));
const stormMs = Date.now() - stormStart;
stopPolling = true;
await poll;

latencies.sort((a, b) => a - b);
const eld = eldSamples.map((s) => s.event_loop_delay_ms);
const invalidTotal = rejected + validBounced;
const rejectionRate = invalidTotal === 0 ? 0 : rejected / invalidTotal;

const summary = {
  lane: "n2",
  surface: "next16-server-action",
  op: "action-storm",
  vus: VUS,
  iters_per_vu: ITERS,
  planned_requests: VUS * ITERS,
  accepted,
  rejected,
  invalid_total: invalidTotal,
  valid_bounced: validBounced,
  rejection_rate: Number(rejectionRate.toFixed(6)),
  transport_errors: transportErr,
  transport_error_codes: transportCodes,
  unexpected_status: unexpectedStatus,
  double_submission_pairs: doubleSubmissionPairs,
  session_leaks: sessionLeaks,
  unique_rids: ridSeen.size,
  duration_ms: stormMs,
  warmup_ms: warmupMs,
  ops_per_sec: Number(((accepted + rejected) / (stormMs / 1000)).toFixed(1)),
  p50_ms: Number(percentile(latencies, 50).toFixed(2)),
  p90_ms: Number(percentile(latencies, 90).toFixed(2)),
  p95_ms: Number(percentile(latencies, 95).toFixed(2)),
  p99_ms: Number(percentile(latencies, 99).toFixed(2)),
  max_ms: latencies.length ? Number(latencies[latencies.length - 1].toFixed(2)) : 0,
  eld_samples: eldSamples.length,
  eld_mean_ms: eld.length ? Number((eld.reduce((a, s) => a + s.mean, 0) / eld.length).toFixed(3)) : null,
  eld_p99_max_ms: eld.length ? Number(Math.max(...eld.map((s) => s.p99)).toFixed(3)) : null,
  eld_max_ms: eld.length ? Number(Math.max(...eld.map((s) => s.max)).toFixed(3)) : null,
  machine: {
    cpu: os.cpus()[0]?.model,
    cores: os.cpus().length,
    node: process.version,
    darwin: os.release(),
  },
};

console.log(JSON.stringify(summary, null, 2));

const f1 = sessionLeaks === 0 && transportErr === 0 && unexpectedStatus === 0;
const f2 = invalidTotal > 0 && rejectionRate === 1;
const f3 = summary.p99_ms <= 350;
console.error(`F1 session_leak: ${f1 ? "PASS" : "FAIL"} (leaks=${sessionLeaks}, transport_err=${transportErr}, unexpected_status=${unexpectedStatus})`);
console.error(`F2 invalid_rejection_100pct: ${f2 ? "PASS" : "FAIL"} (${rejected}/${invalidTotal})`);
console.error(`F3 p99<=350ms: ${f3 ? "PASS" : "FAIL"} (p99=${summary.p99_ms}ms)`);

if (OUT) {
  fs.mkdirSync(new URL(".", `file://${process.cwd()}/${OUT}`).pathname, { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(summary) + "\n");
}

agent.destroy();
process.exit(f1 && f2 && f3 ? 0 : 1);
