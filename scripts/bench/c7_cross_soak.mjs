// c7_cross_soak.mjs — lane C-7: FULL cross-surface soak (the interference
// matrix). Six surfaces hammered SIMULTANEOUSLY for 600 s against one live
// substrate on the c7 private port block (lib.sh port law: c7 -> 39270..39275):
//
//   blob   — 8 KiB put via @azure/storage-blob          (egress 39271)
//   cosmos — point-read + create via @azure/cosmos      (egress 39271)
//   sb     — send, sessionless, @azure/service-bus      (amqp 39272)
//   eh     — send via @azure/event-hubs                 (ehub 39273)
//   kv     — encrypt RSA-OAEP-256 @azure/keyvault-keys  (arm_tls 39274)
//   arm    — raw REST GET /subscriptions                (arm 39270)
//
// Every 10 s: per-surface ops/s (10 s window), substrate beam RSS, cumulative
// per-surface error counts. Each surface gets its own container/db/queue/hub/
// key; the substrate is the only shared resource.
//
// Solo baselines for the interference matrix (prior lanes, same machine):
//   blob 8k put 4351.17 ops/s (b2), cosmos point-read 4405.29 (b3),
//   sb send 50.6 (b4, KD-20 link-credit residual), eh send 324.7 (b4),
//   kv encrypt / arm list: no prior solo bench — baseline N/A.
//
// Run: node scripts/bench/c7_cross_soak.mjs
// Output: docs/jira/v26.10.14/bench/c7-cross-soak.jsonl
import { spawn, execSync } from "node:child_process";
import net from "node:net";
import https from "node:https";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

// KV plane TLS: the vault port serves a cert signed by the private dev CA
// (.smalt/tls/ca-cert.pem). The Azure SDK uses node:https, which honors
// NODE_EXTRA_CA_CERTS — re-exec with it wired (undici fetch would ignore it,
// so the KV raw call uses node:https with rejectUnauthorized:false instead).
if (!process.env.NODE_EXTRA_CA_CERTS) {
  const { spawn: re } = await import("node:child_process");
  const c = re(process.execPath, process.argv.slice(1), {
    stdio: "inherit",
    env: { ...process.env, NODE_EXTRA_CA_CERTS: path.join(REPO, "tmp/dev-certs/dev-cert-39274.pem") },
  });
  c.on("exit", (code) => process.exit(code ?? 0));
  await new Promise(() => {}); // park parent; child carries on with the CA
}


const SDK_DIR = path.join(REPO, "test/sdk-full");
const OUT =
  process.env.C7_OUT ||
  path.join(REPO, "docs/jira/v26.10.14/bench/c7-cross-soak.jsonl");

// c-law block: 39200 + 7*10 = 39270 (disjoint from the b-law band).
const ARM_P = 39270, EGRESS_P = 39271, AMQP_P = 39272, EHUB_P = 39273,
  ATLS_P = 39274, MCP_P = 39275;

const DURATION_MS = Number(process.env.C7_DURATION_MS || 600_000);
const SAMPLE_MS = 10_000;
const PAYLOAD = randomBytes(8 * 1024);  // blob 8 KiB — b2 solo comparable
const MSG_PAYLOAD = randomBytes(1024);  // 1 KiB — b4 solo comparable
const TAG = Date.now();
const STOP = { flag: false };

const { BlobServiceClient, StorageSharedKeyCredential } = await import(
  path.join(SDK_DIR, "node_modules/@azure/storage-blob/dist/esm/index.js"));
const { CosmosClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/cosmos/dist/esm/index.js"));
const { ServiceBusClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/service-bus/dist/esm/index.js"));
const { EventHubProducerClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/event-hubs/dist/esm/index.js"));
const { CryptographyClient } = await import(
  path.join(SDK_DIR, "node_modules/@azure/keyvault-keys/dist/esm/index.js"));

// ---------------------------------------------------------------- substrate
const sharedKey = randomBytes(48).toString("base64");
const ERL_NAME = "c7sub";
const COOKIE = "c7soak";
let substrate = null;

function portBusy(p) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1200 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("error", () => resolve(false));
    s.once("timeout", () => { s.destroy(); resolve(true); });
  });
}

async function bootSubstrate() {
  const ports = [ARM_P, EGRESS_P, AMQP_P, EHUB_P, ATLS_P, MCP_P];
  for (const p of ports) {
    if (await portBusy(p)) {
      console.error(`[c7] port ${p} already held — refusing to boot (collision)`);
      process.exit(3);
    }
  }
  try {
    fs.rmSync(path.join(REPO, "tmp/dev-certs/dev-cert-39274.pem"), { force: true });
    fs.rmSync(path.join(REPO, "tmp/dev-certs/dev-key-39274.pem"), { force: true });
  } catch {}
  const logPath = path.join(REPO, "tmp/bench-substrate-c7.log");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const evalCode = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP_P}")`,
    `Application.put_env(:smalt, :arm_port, ${ARM_P})`,
    `Application.put_env(:smalt, :egress_port, ${EGRESS_P})`,
    `Application.put_env(:smalt, :amqp_port, ${AMQP_P})`,
    `Application.put_env(:smalt, :event_hubs_port, ${EHUB_P})`,
    `Application.put_env(:smalt, :arm_tls_port, ${ATLS_P})`,
    `Application.put_env(:smalt, :mcp_port, ${MCP_P})`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
    `Process.sleep(:infinity)`,
  ].join("; ");
  const child = spawn("mix", ["run", "--no-start", "-e", evalCode, "--no-halt"], {
    cwd: REPO,
    env: {
      ...process.env,
      MIX_ENV: "test",
      ELIXIR_ERL_OPTIONS: `-name ${ERL_NAME}@127.0.0.1 -setcookie ${COOKIE}`,
    },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);
  const t0 = Date.now();
  for (;;) {
    if ((await portBusy(ARM_P)) === true) break;
    if (Date.now() - t0 > 120_000) {
      console.error(`[c7] substrate failed to listen on ${ARM_P} in 120s; log: ${logPath}`);
      killSubstrate();
      process.exit(2);
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  // Readiness: ALL ports must accept TCP — ARM listens first, TLS last.
  for (const p of ports) {
    let up = false;
    for (let i = 0; i < 60; i++) {
      if (!(await portBusy(p))) { await new Promise((r) => setTimeout(r, 1000)); continue; }
      // portBusy(true) means held; verify a real TCP connect succeeds
      up = await new Promise((resolve) => {
        const s2 = net.connect({ host: "127.0.0.1", port: p, timeout: 1500 });
        s2.once("connect", () => { s2.destroy(); resolve(true); });
        s2.once("error", () => resolve(false));
        s2.once("timeout", () => { s2.destroy(); resolve(false); });
      });
      if (up) break;
      await new Promise((r) => setTimeout(r, 1000));
      up = false;
    }
    if (!up) { console.error(`[c7] port ${p} never accepted TCP — aborting`); killSubstrate(); process.exit(2); }
  }
  console.log(`[c7] substrate up pid=${child.pid} ports=${ports.join("/")}`);
  substrate = child;
}

function killSubstrate() {
  if (!substrate) return;
  try {
    if (substrate.pid && substrate.exitCode === null) {
      try { process.kill(-substrate.pid, "SIGTERM"); }
      catch { substrate.kill("SIGTERM"); }
    }
  } catch { /* gone */ }
}

// Beam RSS: the `mix run` wrapper's BEAM child (largest rss among mix/beam).
function beamRssKb() {
  try {
    const out = execSync(
      "ps -axo pid,ppid,rss,command | grep -E 'beam.smp' | grep -v grep || true",
      { encoding: "utf8" });
    let best = null;
    for (const line of out.split("\n")) {
      const m = line.trim().split(/\s+/);
      if (m.length < 4) continue;
      const rss = Number(m[2]);
      if (Number.isFinite(rss) && (!best || rss > best.rss)) best = { pid: Number(m[0]), rss };
    }
    return best;
  } catch { return null; }
}

// erlang.memory 5x via a short-lived distribution node RPCing the substrate.
async function erlangMemorySample() {
  const script = [
    ":net_kernel.stop()",
    `:net_kernel.start([:'c7probe', %{name_domain: :shortnames}])`,
    `:erlang.set_cookie(:'${ERL_NAME}', :'${COOKIE}')`,
    `true = Node.connect(:'${ERL_NAME}@127.0.0.1')`,
    `m = :rpc.call(:'${ERL_NAME}@127.0.0.1', :erlang, :memory, [])`,
    `IO.puts("ErlangMemory total=" <> Integer.to_string(div(Keyword.get(m, :total, 0), 1024)) <> "kb processes=" <> Integer.to_string(div(Keyword.get(m, :processes, 0), 1024)) <> "kb ets=" <> Integer.to_string(div(Keyword.get(m, :ets, 0), 1024)) <> "kb binary=" <> Integer.to_string(div(Keyword.get(m, :binary, 0), 1024)) <> "kb")`,
    "System.halt(0)",
  ].join("; ");
  return new Promise((resolve) => {
    const c = spawn("mix", ["run", "--no-start", "-e", script], {
      cwd: REPO,
      env: { ...process.env, MIX_ENV: "test" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let buf = "";
    c.stdout.on("data", (d) => { buf += d; });
    c.stderr.on("data", (d) => { buf += d; });
    const t = setTimeout(() => { try { c.kill("SIGKILL"); } catch {} resolve("timeout"); }, 90_000);
    c.on("exit", () => {
      clearTimeout(t);
      const m = buf.match(/ErlangMemory(ConnectFailed)?[^\n]*/);
      resolve(m ? m[0] : buf.slice(-160).replace(/\n/g, " "));
    });
  });
}

// ---------------------------------------------------------------- JSONL
fs.mkdirSync(path.dirname(OUT), { recursive: true });
function emit(obj) {
  const line = JSON.stringify({ lane: "c7", ts: new Date().toISOString(), ...obj });
  fs.appendFileSync(OUT, line + "\n");
}

// ---------------------------------------------------------------- state
function mkSurface(name) {
  return { name, n: 0, winOps: 0, errs: 0, lastErr: "", winLat: [], lat: [] };
}
const S = {
  blob: mkSurface("blob"),
  cosmos: mkSurface("cosmos"),
  sb: mkSurface("sb"),
  eh: mkSurface("eh"),
  kv: mkSurface("kv"),
  arm: mkSurface("arm"),
};
const stat = (v, p) => {
  if (!v.length) return 0;
  const s = [...v].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.round((p / 100) * (s.length - 1)))];
};
const noteErr = (surf, e) => {
  surf.errs++;
  surf.lastErr = String((e && e.message) || e).slice(0, 200);
};
const withTimeout = (p, ms = 20_000, tag = "C7_OP_TIMEOUT") =>
  Promise.race([p, new Promise((_, rej) =>
    setTimeout(() => rej(Object.assign(new Error(tag), { code: tag })), ms))]);

// ---------------------------------------------------------------- workers
async function blobWorker() {
  const ACCOUNT = "smaltacct";
  const service = new BlobServiceClient(
    `http://127.0.0.1:${EGRESS_P}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, "smaltacct-key"));
  const container = service.getContainerClient(`c7-${TAG}`);
  const res = await fetch(container.url, {
    method: "PUT",
    headers: { "x-ms-version": "2021-12-02", "x-ms-immutable-policy": "false" },
    signal: AbortSignal.timeout(30_000),
  });
  if (res.status !== 201) {
    throw new Error(`container create ${res.status} ${(await res.text()).slice(0, 150)}`);
  }
  const blob = container.getBlockBlobClient("c7-8k");
  for (;;) {
    const t0 = process.hrtime.bigint();
    try {
      await blob.upload(PAYLOAD, PAYLOAD.length, { abortSignal: AbortSignal.timeout(30_000) });
      S.blob.n++; S.blob.winOps++;
      S.blob.winLat.push(Number(process.hrtime.bigint() - t0) / 1e6);
    } catch (e) { noteErr(S.blob, e); }
  }
}

async function cosmosWorker() {
  const client = new CosmosClient({
    endpoint: `http://127.0.0.1:${EGRESS_P}`,
    key: randomBytes(32).toString("hex"),
    retryOptions: { maxRetryAttemptCount: 0 },
    connectionPolicy: { enableEndpointsDiscovery: false },
  });
  const { database } = await client.databases.createIfNotExists({ id: `c7db-${TAG}` });
  const { container } = await database.containers.createIfNotExists(
    { id: "c1", partitionKey: { paths: ["/pk"] } });
  await container.items.create({ id: "seed-0", pk: "p1", value: "c7" });
  const item = container.item("seed-0", "p1");
  let i = 0;
  for (;;) {
    const t0 = process.hrtime.bigint();
    try {
      if (i % 2 === 0) {
        await item.read({ abortSignal: AbortSignal.timeout(30_000) });
      } else {
        await container.items.create({ id: `c7-${i}`, pk: "p1", value: i });
      }
      S.cosmos.n++; S.cosmos.winOps++;
      S.cosmos.winLat.push(Number(process.hrtime.bigint() - t0) / 1e6);
    } catch (e) { noteErr(S.cosmos, e); }
    i++;
  }
}

async function sbWorker() {
  const CS = `Endpoint=sb://127.0.0.1:${AMQP_P};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${sharedKey};UseDevelopmentEmulator=true`;
  let client = new ServiceBusClient(CS, { retryOptions: { maxRetries: 0, timeoutInMs: 30000 } });
  const queue = `c7-q-${TAG}`;
  let sender = client.createSender(queue);
  let sinceRecycle = 0;
  for (;;) {
    const t0 = process.hrtime.bigint();
    try {
      await withTimeout(
        sender.sendMessages({ body: MSG_PAYLOAD, contentType: "application/octet-stream" },
          { timeoutInMs: 5000 }), 8_000);
      S.sb.n++; S.sb.winOps++;
      S.sb.winLat.push(Number(process.hrtime.bigint() - t0) / 1e6);
      sinceRecycle++;
      if (sinceRecycle >= 800) {
        // Cycle: close sender, BOUNDED drain of the queue (send-then-drain,
        // b4's roundtrip shape), reopen sender. KD-20 residual means the
        // substrate never replenishes fixed link credit, so cycling is load-
        // bearing, not decoration.
        await sender.close().catch(() => {});
        const rxClient = new ServiceBusClient(CS, { retryOptions: { maxRetries: 0, timeoutInMs: 10000 } });
        const rx = rxClient.createReceiver(queue, { receiveMode: "receiveAndDelete" });
        const drainDeadline = Date.now() + 3000;
        for (;;) {
          try {
            const msgs = await rx.receiveMessages(100, { maxWaitTimeInMs: 500 });
            // receiveAndDelete: peekLock settlement (completeMessage) fails on
            // this substrate for batched receives ("no message ID"), which
            // wedges the queue; fire-and-forget drain keeps the queue honest.
            S.sb.received = (S.sb.received || 0) + msgs.length;
            if (!msgs.length || Date.now() > drainDeadline) break;
          } catch (e) {
            if (!S.sb.rxFirstErr) S.sb.rxFirstErr = String((e && e.message) || e).slice(0, 200);
            break;
          }
        }
        await rx.close().catch(() => {});
        await rxClient.close().catch(() => {});
        sender = client.createSender(queue);
        sinceRecycle = 0;
        S.sb.recycles = (S.sb.recycles || 0) + 1;
      }
    } catch (e) {
      noteErr(S.sb, e);
      if (!S.sb.firstErr) S.sb.firstErr = String(e && (e.stack || e.message) || e).slice(0, 300);
      await sender.close().catch(() => {});
      sender = client.createSender(queue);
      sinceRecycle = 0;
      await new Promise((r) => setTimeout(r, 200));
    }
  }
}

async function ehWorker() {
  const CS = `Endpoint=sb://127.0.0.1:${EHUB_P};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${sharedKey};EntityPath=c7-hub;UseDevelopmentEmulator=true`;
  let producer = new EventHubProducerClient(CS, "c7-hub",
    { retryOptions: { maxRetries: 0, timeoutInMs: 30000 } });
  let sinceRecycle = 0;
  for (;;) {
    const t0 = process.hrtime.bigint();
    try {
      const batch = await producer.createBatch();
      if (!batch.tryAdd({ body: MSG_PAYLOAD })) throw new Error("batch.tryAdd rejected 1KiB event");
      await withTimeout(producer.sendBatch(batch), 30_000);
      S.eh.n++; S.eh.winOps++;
      S.eh.winLat.push(Number(process.hrtime.bigint() - t0) / 1e6);
    } catch (e) {
      noteErr(S.eh, e);
      if (!S.eh.firstErr) S.eh.firstErr = String(e && (e.stack || e.message) || e).slice(0, 300);
      await producer.close().catch(() => {});
      producer = new EventHubProducerClient(CS, "c7-hub",
        { retryOptions: { maxRetries: 0, timeoutInMs: 30000 } });
      sinceRecycle = 0;
      S.eh.recycles = (S.eh.recycles || 0) + 1;
      await new Promise((r) => setTimeout(r, 200)); // backoff: never hot-spin
    }
  }
}

async function mintBearer() {
  const body = new URLSearchParams({
    grant_type: "client_credentials", client_id: "c7-soak", client_secret: "dev",
  });
  const res = await fetch(`http://127.0.0.1:${ARM_P}/oauth2/v2.0/token`, { method: "POST", body });
  if (!res.ok) throw new Error(`STS mint failed ${res.status}`);
  return (await res.json()).access_token;
}

async function kvWorker() {
  const VAULT = `https://127.0.0.1:${ATLS_P}`;
  const bearer = await mintBearer();
  const keyName = `c7-crypto-${TAG}`;
  const r = await new Promise((resolve, reject) => {
    const bodyStr = JSON.stringify({ kty: "RSA" });
    const req = https.request(`${VAULT}/keys/${keyName}/create?api-version=7.4`, {
      method: "POST",
      rejectUnauthorized: false, // private dev CA; SDK calls use allowInsecureConnection
      headers: { authorization: `Bearer ${bearer}`, "content-type": "application/json",
        "content-length": Buffer.byteLength(bodyStr) },
      timeout: 15000,
    }, resolve);
    req.on("timeout", () => req.destroy(new Error("kv create timeout")));
    req.on("error", reject);
    req.end(bodyStr);
  });
  const rText = await new Promise((res2, rej2) => {
    let b = ""; r.on("data", (c) => { b += c; }); r.on("end", () => res2(b)); r.on("error", rej2);
  });
  if (r.statusCode !== 200) throw new Error(`key create ${r.statusCode} ${rText.slice(0, 150)}`);
  const cred = {
    getToken: async () => ({ token: bearer, expiresOnTimestamp: Date.now() + 3600_000 }),
  };
  const cryptoClient = new CryptographyClient(`${VAULT}/keys/${keyName}`, cred, {
    allowInsecureConnection: true,
    disableChallengeResourceVerification: true, // vault-uri is 127.0.0.1
    retryOptions: { maxRetries: 0 },
  });
  // The substrate never issues a 401 + WWW-Authenticate challenge, so the SDK
  // never attaches the token — force it via a Sign-phase pipeline policy
  // (same technique as test/sdk-full/keyvault.probe.mjs).
  const pipeline = cryptoClient.client?.pipeline;
  if (pipeline?.addPolicy) {
    pipeline.addPolicy({
      name: "force-bearer",
      sendRequest: (req, next) => { req.headers.set("authorization", `Bearer ${bearer}`); return next(req); },
    }, { phase: "Sign" });
  }
  const plain = Buffer.alloc(32, 7);
  for (;;) {
    const t0 = process.hrtime.bigint();
    try {
      await cryptoClient.encrypt(
        { algorithm: "RSA-OAEP-256", plaintext: plain },
        { abortSignal: AbortSignal.timeout(30_000) });
      S.kv.n++; S.kv.winOps++;
      S.kv.winLat.push(Number(process.hrtime.bigint() - t0) / 1e6);
    } catch (e) {
      noteErr(S.kv, e);
      if (!S.kv.firstErr) S.kv.firstErr = String(e && (e.stack || e.message) || e).slice(0, 300);
      await new Promise((r) => setTimeout(r, 200)); // backoff: never hot-spin
    }
  }
}

async function armWorker() {
  for (;;) {
    const t0 = process.hrtime.bigint();
    try {
      const res = await fetch(`http://127.0.0.1:${ARM_P}/subscriptions?api-version=2021-04-01`,
        { signal: AbortSignal.timeout(30_000) });
      if (!res.ok) throw new Error(`status ${res.status}`);
      await res.text();
      S.arm.n++; S.arm.winOps++;
      S.arm.winLat.push(Number(process.hrtime.bigint() - t0) / 1e6);
    } catch (e) { noteErr(S.arm, e); }
  }
}

// ---------------------------------------------------------------- main
const results = [];
async function main() {
  await bootSubstrate();
  emit({
    event: "meta", duration_s: DURATION_MS / 1000, sample_interval_s: SAMPLE_MS / 1000,
    ports: { arm: ARM_P, egress: EGRESS_P, amqp: AMQP_P, ehub: EHUB_P, atls: ATLS_P, mcp: MCP_P },
    payload_bytes: { blob: PAYLOAD.length, sb_eh: MSG_PAYLOAD.length },
  });

  const SELECT = (process.env.C7_WORKERS || "blob,cosmos,sb,eh,kv,arm").split(",");
  const mk = (name, fn) =>
    SELECT.includes(name)
      ? fn().catch((e) => results.push({ event: "worker-crash", surface: name, detail: String(e).slice(0, 300) }))
      : null;
  const workers = [
    mk("blob", blobWorker),
    mk("cosmos", cosmosWorker),
    mk("sb", sbWorker),
    mk("eh", ehWorker),
    mk("kv", kvWorker),
    mk("arm", armWorker),
  ];

  const started = Date.now();
  let sampleNo = 0;
  const memTimes = [120_000, 240_000, 360_000, 480_000, 590_000].map((t) => started + t);
  let memIdx = 0;

  while (Date.now() - started < DURATION_MS) {
    await new Promise((r) => setTimeout(r, SAMPLE_MS));
    sampleNo++;
    const rss = beamRssKb();
    const heap = process.memoryUsage();
    const sample = {
      event: "sample", n: sampleNo, elapsed_s: Math.round((Date.now() - started) / 1000),
      rss_kb: rss ? rss.rss : null, rss_pid: rss ? rss.pid : null,
      heap_mb: Number((heap.heapUsed / 1048576).toFixed(1)),
      ops_per_surface: {}, win_errors: {}, total_ops: {}, cum_errors: {},
    };
    for (const name of Object.keys(S)) {
      const surf = S[name];
      sample.ops_per_surface[name] = Number((surf.winOps / (SAMPLE_MS / 1000)).toFixed(1));
      sample.win_errors[name] = surf.winErrs !== undefined ? surf.winErrs : 0;
      sample.total_ops[name] = surf.n;
      sample.cum_errors[name] = surf.errs;
      if (surf.winLat.length) {
        sample[`p50_${name}`] = Number(stat(surf.winLat, 50).toFixed(3));
        sample[`p95_${name}`] = Number(stat(surf.winLat, 95).toFixed(3));
      }
      surf.lat.push(...surf.winLat.slice(0, 5000));
      if (surf.lat.length > 200_000) surf.lat = surf.lat.slice(-100_000);
      surf.winOps = 0;
      surf.winErrs = 0;
      surf.winLat = [];
    }
    emit(sample);
    if (memIdx < memTimes.length && Date.now() >= memTimes[memIdx]) {
      memIdx++;
      const mem = await erlangMemorySample();
      emit({ event: "erlang-memory", elapsed_s: Math.round((Date.now() - started) / 1000), detail: mem });
    }
  }

  // stop workers
  for (const r of results) emit(r);
  killSubstrate();

  const wallS = (Date.now() - started) / 1000;
  for (const name of Object.keys(S)) {
    const surf = S[name];
    const p50 = stat(surf.lat, 50), p95 = stat(surf.lat, 95), p99 = stat(surf.lat, 99);
    emit({
      event: "summary", surface: name, n: surf.n,
      ops_per_sec: Number((surf.n / wallS).toFixed(2)),
      p50_ms: Number(p50.toFixed(3)), p95_ms: Number(p95.toFixed(3)), p99_ms: Number(p99.toFixed(3)),
      errors: surf.errs, recycles: surf.recycles || 0,
      last_error: surf.errs ? surf.lastErr : "",
      first_error: surf.firstErr || "",
      received: surf.received || 0,
      rx_first_error: surf.rxFirstErr || "",
      queues: surf.queues || 0,
    });
  }
  emit({ event: "done", wall_s: Number(wallS.toFixed(1)) });
  console.log("[c7] done —", OUT);
  process.exit(0);
}

main().catch((e) => {
  console.error("[c7] FAILED", e);
  emit({ event: "harness-failed", detail: String(e && e.stack || e).slice(0, 500) });
  killSubstrate();
  process.exit(1);
});
