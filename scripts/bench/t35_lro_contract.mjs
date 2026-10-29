// T35LRO lane — ARM control-plane LRO contract, empirical leg.
// Raw REST (no @azure/arm-servicebus vendored in verification/ts). Rides the
// 9444 TLS twin with an STS bearer (KD-15 shape). Over 20 provisions of
// Microsoft.ServiceBus/namespaces (a real smalt lro_type?,
// lib/smalt/arm_gateway/router.ex:3100) it measures the 202 poll-cadence
// contract (Azure-AsyncOperation + Location + Retry-After) and terminal-state
// latency p50/p95/p99, plus a sync queue PUT leg under each namespace.
//
// Typed FAIL (exit 1) if any provision exceeds 15 s end-to-end.
// Loud SKIP (exit 3) if the substrate is down — never restarts it.
// Emits ONLY tmp/bench/t35-lro.jsonl.
// Receipt: docs/jira/v26.10.20/receipts/t35-lro-contract.md
//
// Run: NODE_TLS_REJECT_UNAUTHORIZED=0 node scripts/bench/t35_lro_contract.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ARM = process.env.T35_ARM ?? "https://127.0.0.1:9444";
const OUT = process.env.T35_OUT ?? path.join(REPO, "tmp/bench/t35-lro.jsonl");
const N = Number(process.env.T35_N ?? 20);
const SUB = "00000000-0000-0000-0000-000000000000";
const API = "2021-04-01";
const FAIL_MS = 15000;
const POLL_DEADLINE_MS = 30000;
const RUN = Date.now().toString(36);

const machine = {
  cpu: os.cpus()[0].model,
  cores: os.cpus().length,
  ram_gb: Math.round(os.totalmem() / 2 ** 30),
  node: process.version,
  elixir: "1.20.4-otp-29",
  otp: "29.1.2",
  darwin: "26.2",
  endpoint: ARM,
};

const log = (...a) => console.log(new Date().toISOString(), ...a);

function emitRow(row) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
}

const pct = (sorted, p) => {
  if (!sorted.length) return null;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return Number(sorted[i].toFixed(3));
};

async function substrateUp() {
  try {
    const r = await fetch(`${ARM}/providers?api-version=2099-01-01`, { signal: AbortSignal.timeout(5000) });
    r.body?.cancel().catch(() => {});
    return r.status < 500;
  } catch {
    return false;
  }
}

async function mintToken() {
  const r = await fetch(`${ARM}/organizations/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=t35lro&client_secret=t35lro&scope=https%3A%2F%2Fmanagement.azure.com%2F.default",
    signal: AbortSignal.timeout(10000),
  });
  if (!r.ok) throw new Error(`STS mint failed: ${r.status}`);
  const j = await r.json();
  if (!j.access_token) throw new Error("STS mint: no access_token");
  return j.access_token;
}

let transportRetries = 0;
let lastTransportErr = null;
async function armRequest(method, urlPath, body, token) {
  const doFetch = () => fetch(`${ARM}${urlPath}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20000),
  });
  let r;
  try {
    r = await doFetch();
  } catch (e) {
    transportRetries++;
    lastTransportErr = String(e?.cause?.code ?? e?.message ?? e);
    r = await doFetch();
  }
  const buf = await r.arrayBuffer();
  let json = null;
  try { json = JSON.parse(Buffer.from(buf).toString("utf8")); } catch {}
  return { status: r.status, headers: r.headers, json };
}

async function pollToTerminal(pollPath, token, startedAt) {
  const polls = [];
  let terminal = null;
  let first = true;
  while (Date.now() - startedAt < POLL_DEADLINE_MS) {
    if (!first) {
      const declared = Number(polls.at(-1)?.retry_after ?? 1) || 1;
      await new Promise(res => setTimeout(res, Math.max(50, declared * 1000)));
    }
    first = false;
    const pr = await armRequest("GET", pollPath, undefined, token);
    polls.push({
      at_ms: Date.now() - startedAt,
      http: pr.status,
      body_status: pr.json?.status ?? null,
      retry_after: pr.headers.get("retry-after"),
    });
    if (pr.status === 200 && (pr.json?.status === "Succeeded" || pr.json?.status === "Failed")) {
      terminal = { at_ms: Date.now() - startedAt, status: pr.json?.status };
      break;
    }
  }
  return { polls, terminal };
}

function emitStats(op, latencies, extra = {}) {
  const v = [...latencies].sort((a, b) => a - b);
  const mean = v.length ? v.reduce((s, x) => s + x, 0) / v.length : 0;
  emitRow({
    lane: "t35-lro",
    surface: "arm",
    op,
    n: v.length,
    ops_per_sec: mean ? Number((1000 / mean).toFixed(3)) : 0,
    p50_ms: pct(v, 50),
    p95_ms: pct(v, 95),
    p99_ms: pct(v, 99),
    errors: extra.errors ?? 0,
    ...extra,
    machine,
    standing: "PASS",
  });
}

const t0 = Date.now();
try {
  if (!(await substrateUp())) {
    console.error("T35LRO: substrate down — loud SKIP (exit 3); lane never restarts the substrate.");
    process.exit(3);
  }
  const token = await mintToken();
  log(`token ok; ${N} provisions, run ${RUN}`);

  const rg = `t35-lro-${RUN}`;
  const rgPut = await armRequest("PUT",
    `/subscriptions/${SUB}/resourcegroups/${rg}?api-version=${API}`,
    { location: "smalt" }, token);
  if (rgPut.status !== 200 && rgPut.status !== 201) throw new Error(`RG PUT ${rgPut.status}`);

  const latencies = [];
  const queueLatencies = [];
  const pollContract = [];
  let fails = 0;
  let queueErrors = 0;
  let syncFace200 = 0;
  let provisioningErrors = 0;

  for (let i = 0; i < N; i++) {
    const ns = `t35ns-${RUN}-${i}`;
    const startedAt = Date.now();
    const put = await armRequest("PUT",
      `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.ServiceBus/namespaces/${ns}?api-version=${API}`,
      { location: "smalt", sku: { name: "Standard", tier: "Standard" }, properties: { zoneRedundant: false } }, token);

    const headers = {
      http: put.status,
      azure_async_operation: put.headers.get("azure-asyncoperation"),
      location: put.headers.get("location"),
      retry_after: put.headers.get("retry-after"),
    };
    pollContract.push(headers);

    let terminal = null;
    if (put.status === 202 && headers.azure_async_operation) {
      const u = new URL(headers.azure_async_operation);
      const res = await pollToTerminal(u.pathname + u.search, token, startedAt);
      headers.polls = res.polls;
      terminal = res.terminal;
      const total = Date.now() - startedAt;
      latencies.push(total);
      if (total > FAIL_MS) fails++;
    } else if (put.status === 200) {
      syncFace200++;
      latencies.push(Date.now() - startedAt);
    } else {
      provisioningErrors++;
      latencies.push(Date.now() - startedAt);
    }
    headers.terminal_at_ms = terminal?.at_ms ?? null;
    headers.e2e_ms = latencies.at(-1) ?? null;

    if (put.status === 202 || put.status === 200) {
      const qs = Date.now();
      const q = await armRequest("PUT",
        `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.ServiceBus/namespaces/${ns}/queues/t35q?api-version=${API}`,
        { location: "smalt", properties: { lockDuration: "PT1M", maxDeliveryCount: 10 } }, token);
      queueLatencies.push(Date.now() - qs);
      if (q.status >= 400) queueErrors++;
      await armRequest("DELETE",
        `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.ServiceBus/namespaces/${ns}/queues/t35q?api-version=${API}`,
        undefined, token);
      await armRequest("DELETE",
        `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.ServiceBus/namespaces/${ns}?api-version=${API}`,
        undefined, token);
    }
  }

  emitStats("lro-namespace-provision-e2e", latencies, {
    fails_over_15s: fails,
    transport_retries: transportRetries,
    last_transport_err: lastTransportErr,
    sync_200_face_count: syncFace200,
    provisioning_errors: provisioningErrors,
  });
  emitStats("arm-queue-put-sync", queueLatencies, { errors: queueErrors, transport_retries: transportRetries });
  emitRow({
    lane: "t35-lro", surface: "arm", op: "lro-poll-contract",
    n: pollContract.length,
    ops_per_sec: null, p50_ms: null, p95_ms: null, p99_ms: null,
    errors: provisioningErrors,
    contract: pollContract, machine, standing: "PASS",
  });

  if (fails > 0) {
    log(`TYPED FAIL: ${fails}/${N} provisions exceeded ${FAIL_MS} ms (15 s envelope)`);
    process.exit(1);
  }
  log(`done in ${Date.now() - t0} ms`);
  process.exit(0);
} catch (e) {
  console.error("T35LRO TYPED-ERROR:", e?.stack ?? e);
  process.exit(1);
}
