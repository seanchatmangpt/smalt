// T36BOOT lane — boot determinism court (cold-start claim).
// Boots 3 fresh private-port substrates SEQUENTIALLY (port blocks 39760/39770/
// 39780, MIX_ENV=test anonymous auth, lifecycle_harness-style spawn with no fd
// inheritance, never touches the shared substrate), runs the same 10-check
// health sequence against each, and asserts structural identity across boots
// (same status codes + shape-kind; GUIDs/ports/timestamps may differ).
// Measures cold-boot-to-ready wall per boot; judges only the <10s operational
// bound as pass/fail — the NFR's 500ms aspiration is reported as an explicit
// gap, not judged.
//
// Typed verdict: PASS (3/3 boots green, structurally identical, all walls
// <10s) / FAIL (any red, divergent, or >=10s) / BLOCKED (port collision).
// Emits ONLY tmp/bench/t36-boot.jsonl (lane result-file law).
//
// Run: node scripts/bench/t36_boot_court.mjs
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const OUT = process.env.T36_OUT ?? path.join(REPO, "tmp/bench/t36-boot.jsonl");
const LOG = path.join(REPO, "tmp/t36-boot-substrate.log");
const READY_DEADLINE_MS = 150_000;
const OP_BOUND_MS = 10_000; // operational pass bound
const SUB = "00000000-0000-0000-0000-000000000000";
const BOOT_PORTS = [39760, 39770, 39780];

const machine = {
  cpu: os.cpus()[0].model, cores: os.cpus().length,
  ram_gb: Math.round(os.totalmem() / 2 ** 30),
  node: process.version,
};
const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function emit(row) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
}

async function portUp(p, timeout = 1200) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: p, timeout });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("error", () => resolve(false));
    s.once("timeout", () => { s.destroy(); resolve(false); });
  });
}

async function portsFree(base) {
  for (const p of [base, base + 1, base + 2, base + 3, base + 4, base + 5]) {
    if (await portUp(p, 400)) return { free: false, held: p };
  }
  return { free: true };
}

// ---------------------------------------------------------------------------
// substrate lifecycle
// ---------------------------------------------------------------------------
let sub = null;
async function bootSubstrate(base, bootNo) {
  const pf = await portsFree(base);
  if (!pf.free) throw new Error(`TYPED-BLOCKED: port ${pf.held} held — refusing to boot (collision)`);
  const sharedKey = crypto.randomBytes(48).toString("base64");
  const code = [
    `Application.put_env(:smalt, :arm_port, ${base})`,
    `Application.put_env(:smalt, :egress_port, ${base + 1})`,
    `Application.put_env(:smalt, :amqp_port, ${base + 2})`,
    `Application.put_env(:smalt, :event_hubs_port, ${base + 3})`,
    `Application.put_env(:smalt, :arm_tls_port, ${base + 4})`,
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${base + 2}")`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
    `Process.sleep(:infinity)`,
  ].join("; ");
  fs.mkdirSync(path.dirname(LOG), { recursive: true });
  const logFile = fs.createWriteStream(`${LOG}-${bootNo}`, { flags: "w" });
  sub = spawn("mix", ["run", "--no-start", "--no-halt", "-e", code], {
    cwd: REPO,
    env: { ...process.env, MIX_ENV: "test", MIX_BUILD_ROOT: "_build-t36boot" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  sub.stdout.pipe(logFile); sub.stderr.pipe(logFile);
  const t0 = Date.now();
  for (;;) {
    const ups = await Promise.all([0, 1, 2, 3, 4].map((i) => portUp(base + i)));
    if (ups.every(Boolean)) return { sharedKey };
    if (Date.now() - t0 > READY_DEADLINE_MS) {
      throw new Error(`boot ${bootNo}: not up in ${READY_DEADLINE_MS}ms; log ${LOG}-${bootNo}`);
    }
    await sleep(400); // SLEEP-CLASS: POLL-STEP — bounded readiness poll on LISTEN observables
  }
}
function downSubstrate() {
  if (!sub) return;
  try { process.kill(-sub.pid, "SIGKILL"); } catch { try { sub.kill("SIGKILL"); } catch {} }
  sub = null;
}
process.on("exit", downSubstrate);
process.on("SIGINT", () => process.exit(130));

// ---------------------------------------------------------------------------
// probes
// ---------------------------------------------------------------------------
async function http(method, url, body, headers = {}) {
  try {
    const r = await fetch(url, {
      method,
      headers,
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    const text = await r.text();
    let json = null;
    try { json = JSON.parse(text); } catch {}
    return { status: r.status, json, text, headers: r.headers };
  } catch (e) {
    return { status: 0, json: null, text: String(e?.message ?? e), headers: new Headers() };
  }
}

async function runChecks(base, sharedKey) {
  const ARM = `http://127.0.0.1:${base}`;
  const EGRESS = `http://127.0.0.1:${base + 1}`;
  const t = Date.now().toString(36);
  const out = [];
  const JSONH = { "content-type": "application/json" };

  // 1. metadata/endpoints: providers listing
  let r = await http("GET", `${ARM}/providers?api-version=2021-04-01`);
  out.push(["metadata_providers", r.status, Array.isArray(r.json?.value) ? "value[]" : "shape-miss"]);

  // 2. tenants
  r = await http("GET", `${ARM}/tenants?api-version=2021-04-01`);
  out.push(["tenants", r.status, Array.isArray(r.json?.value) ? "value[]" : "shape-miss"]);

  // 3. STS mint
  r = await http("POST", `${ARM}/organizations/oauth2/v2.0/token`,
    new URLSearchParams({ grant_type: "client_credentials", client_id: "t36", client_secret: "dev" }).toString(),
    { "content-type": "application/x-www-form-urlencoded" });
  const token = r.json?.access_token ?? null;
  out.push(["sts_mint", r.status, token ? "access_token" : "no-token"]);
  const AUTH = token ? { authorization: `Bearer ${token}` } : {};

  // 4. subscriptions
  r = await http("GET", `${ARM}/subscriptions?api-version=2021-04-01`, undefined, AUTH);
  out.push(["subscriptions", r.status, Array.isArray(r.json?.value) ? "value[]" : "shape-miss"]);

  // 5. cosmos create (db)
  r = await http("POST", `${EGRESS}/dbs`, { id: `t36db-${t}` }, {
    "content-type": "application/json",
    "x-ms-date": new Date().toUTCString(),
    "x-ms-version": "2020-07-15",
  });
  out.push(["cosmos_db_create", r.status, r.json?.id !== undefined ? "id" : "shape-miss"]);

  // 6. kv set (KD-15 challenge handshake: tokenless 401 -> bearer resend)
  let kv = await http("PUT", `${EGRESS}/kv/t36-key`, { value: `v-${t}` }, { "content-type": "application/json" });
  const challenged = kv.status === 401;
  if (challenged) {
    kv = await http("PUT", `${EGRESS}/kv/t36-key`, { value: `v-${t}` }, { ...AUTH, "content-type": "application/json" });
  }
  out.push(["kv_set", kv.status, challenged ? "challenge-then-bearer" : "direct"]);

  // 7. blob put (container create, then block blob put)
  const c = await http("PUT", `${EGRESS}/t36acct/t36c-${t}?restype=container`, undefined,
    { "x-ms-version": "2021-12-02" });
  r = await http("PUT", `${EGRESS}/t36acct/t36c-${t}/t36blob.txt`, "hello-t36",
    { "x-ms-blob-type": "BlockBlob", "x-ms-version": "2021-12-02" });
  out.push(["blob_put", r.status, `container_create=${c.status}`]);

  // 8. sb queue create (ARM): rg + namespace are its parents — create them
  // first, then poll the namespace to materialization (its PUT is an LRO)
  await http("PUT", `${ARM}/subscriptions/${SUB}/resourceGroups/t36-rg?api-version=2021-04-01`,
    { location: "eastus" }, { ...AUTH, ...JSONH });
  const nsp = await http("PUT",
    `${ARM}/subscriptions/${SUB}/resourceGroups/t36-rg/providers/Microsoft.ServiceBus/namespaces/t36ns?api-version=2021-04-01`,
    { location: "eastus", properties: { skuName: "Standard" } }, { ...AUTH, ...JSONH });
  let nsOk = false, nsFirst = null, nb = null;
  for (let i = 0; i < 25; i++) {
    const g = await http("GET", `${ARM}/subscriptions/${SUB}/resourceGroups/t36-rg/providers/Microsoft.ServiceBus/namespaces/t36ns?api-version=2021-04-01`, undefined, AUTH);
    if (i === 0) { nsFirst = g.status; nb = g.text; }
    if (g.status === 200) { nsOk = true; break; }
    await sleep(200); // SLEEP-CLASS: POLL-STEP — bounded poll on observable parent existence
  }
  r = await http("PUT",
    `${ARM}/subscriptions/${SUB}/resourceGroups/t36-rg/providers/Microsoft.ServiceBus/namespaces/t36ns/queues/t36q-${t}?api-version=2021-04-01`,
    { location: "eastus", properties: {} }, { ...AUTH, ...JSONH });
  out.push(["sb_queue_create", r.status, `ns_ready=${nsOk}`]);

  // 9. eh send (one event via @azure/event-hubs, UseDevelopmentEmulator)
  try {
    const requireFrom = createRequire(path.join(REPO, "verification/ts/package.json"));
    const { EventHubProducerClient } = requireFrom("@azure/event-hubs");
    const EH_PORT = base + 3;
    const conn =
      `Endpoint=sb://127.0.0.1:${EH_PORT};SharedAccessKeyName=RootManageSharedAccessKey;` +
      `SharedAccessKey=${sharedKey};EntityPath=t36hub;UseDevelopmentEmulator=true`;
    const producer = new EventHubProducerClient(conn, { retryOptions: { maxRetries: 0, timeoutInMs: 15_000 } });
    const batch = await producer.createBatch();
    batch.tryAdd({ body: `t36-evt-${t}` });
    await producer.sendBatch(batch);
    const pids = await producer.getPartitionIds({ abortSignal: AbortSignal.timeout(10_000) });
    out.push(["eh_send", 200, `partitions=${pids.length}`]);
    await producer.close();
  } catch (e) {
    out.push(["eh_send", 1, `err=${String(e?.message ?? e).slice(0, 90)}`]);
  }

  // 10. arm rg create
  r = await http("PUT", `${ARM}/subscriptions/${SUB}/resourceGroups/t36-rg-${t}?api-version=2021-04-01`,
    { location: "eastus" }, { ...AUTH, ...JSONH });
  out.push(["arm_rg_create", r.status, r.json?.location !== undefined ? "location" : "shape-miss"]);

  return out;
}

// --- shape normalization: strip volatile tails so only kind is compared ---
function shapeKind(shape) {
  const s = String(shape);
  if (s.startsWith("err=")) return s.slice(0, 12); // error class only
  return s.replace(/=.*$/, "=").replace(/^challenge|direct$/, "auth-path");
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, ""); // fresh run overwrites

// --- frozen private build root (compile-freeze law): snapshot the last-good
// shared test build ONCE so a concurrent lane's in-flight lib/ edit cannot
// break boots 2..N mid-run. cp -Rp preserves mtimes -> mix sees it fresh. ---
const BUILD_ROOT = path.join(REPO, "_build-t36boot");
{
  const src = path.join(REPO, "_build", "test");
  if (!fs.existsSync(BUILD_ROOT)) {
    fs.cpSync(src, BUILD_ROOT, { recursive: true, verbatimSymlinks: true, preserveTimestamps: true });
    log(`frozen build root: ${BUILD_ROOT} (snapshot of _build/test; first run pays a one-time in-root compile)`);
  } else {
    log(`frozen build root: ${BUILD_ROOT} (reusing populated root)`);
  }
}

const runs = [];
for (const [i, base] of BOOT_PORTS.entries()) {
  const bootNo = i + 1;
  log(`boot ${bootNo}/3 (base port ${base})...`);
  const tSpawn = Date.now();
  let booted;
  try {
    booted = await bootSubstrate(base, bootNo);
  } catch (e) {
    log(String(e.message ?? e));
    emit({ lane: "t36boot", surface: "boot", op: `boot_${bootNo}`, n: 1, ops_per_sec: null,
      p50_ms: null, p95_ms: null, p99_ms: null, errors: 1, machine,
      verdict: String(e.message).includes("TYPED-BLOCKED") ? "BLOCKED" : "FAIL", detail: e.message });
    process.exitCode = 1;
    downSubstrate();
    process.exit(process.exitCode);
  }
  const wall = Date.now() - tSpawn; // spawn -> all 5 listeners up
  const checks = await runChecks(base, booted.sharedKey);
  downSubstrate();
  await sleep(800); // bounded settle so the next boot's block is free
  const errs = checks.filter(([, s]) => s < 200 || s >= 300).length;
  log(`boot ${bootNo}: wall=${wall}ms errors=${errs} :: ${checks.map(([n, s]) => `${n}=${s}`).join(" ")}`);
  runs.push({ bootNo, base, wall, checks, errs });
  emit({ lane: "t36boot", surface: "boot", op: `boot_${bootNo}_wall_ms`, n: 1, ops_per_sec: null,
    p50_ms: wall, p95_ms: wall, p99_ms: wall, errors: errs, machine, boot: bootNo, base_port: base,
    checks: Object.fromEntries(checks.map(([n, s, shape]) => [n, { status: s, shape }])) });
}

// --- determinism: same status + shape-kind across all 3 boots ---
const divergence = [];
if (runs.length === 3) {
  for (const name of runs[0].checks.map(([n]) => n)) {
    const sigs = runs.map((rn) => {
      const c = rn.checks.find(([n]) => n === name);
      return c ? `${c[1]}|${shapeKind(c[2])}` : "missing";
    });
    if (new Set(sigs).size !== 1) divergence.push(`${name}: ${sigs.join(" vs ")}`);
  }
}
let verdict = "PASS";
if (runs.length !== 3 || divergence.length) verdict = "FAIL";
for (const rn of runs) {
  if (rn.errs > 0) verdict = "FAIL";
  if (rn.wall >= OP_BOUND_MS) verdict = "FAIL";
}

const walls = runs.map((r) => r.wall);
log(`verdict=${verdict} walls=${walls.join(",")}ms divergence=${divergence.length}`);
emit({
  lane: "t36boot", surface: "boot", op: "verdict", n: runs.length, ops_per_sec: null,
  p50_ms: null, p95_ms: null, p99_ms: null,
  errors: runs.reduce((a, r) => a + r.errs, 0), machine, verdict,
  walls_ms: walls, op_bound_ms: OP_BOUND_MS,
  nfr_500ms_aspiration_gap_ms: walls.map((w) => w - 500),
  divergence,
});
process.exitCode = verdict === "PASS" ? 0 : 1;
