#!/usr/bin/env node
// c3_eh_blob_archive.mjs — bench lane C-3: Event Hubs -> Blob streaming
// archive (the EH Capture pattern). Event Hubs side runs the REAL
// @azure/event-hubs TS SDK over the live AMQP wire; the blob archive side
// runs raw SharedKey-signed REST (Put Block / Put Block List) because the
// bundled @azure/storage-blob 12.34 stageBlock misframes request bodies on
// keep-alive connections against the substrate (witnessed twice: serializer
// rejects the options-as-contentLength 3-arg call form, and correctly-called
// stageBlock bodies leak onto the connection as Bandit "Request line HTTP
// error" — recorded as findings; raw Put Block with Connection: close is the
// clean transport and is itself what EH Capture does).
//
// Private port block (docs/how-to/dev-loop.md 39000-39999): 39680-39684, disjoint
// from ts-eh-probe 39690-39694 and b1..b12's formula blocks.
//
// Phases:
//   1 STREAM      — producer sends 2000 x 1 KiB events (one event per
//                   createBatch/sendBatch — the one-event-per-send contract,
//                   Q-2 v26.10.15 candidate: multi-event batch delivery drops
//                   events 2..N), consumer archives into rolling block blobs
//                   (64-event stage-block batches, commit every 512 KiB).
//                   events/s archived end-to-end.
//   2 ORDERING    — download the committed blobs, verify per-partition
//                   sequence continuity (EH sequenceNumber + body.i step 1,
//                   no gaps, no duplicates).
//   3 WORM        — same flow into a default-immutable container. FINDING
//                   (witnessed, v26.10.15 candidate): the substrate refuses
//                   the FIRST commit_block_list on a default-immutable
//                   container (409 ContainerLocked) — blob_storage.ex
//                   commit_block_list/6 applies worm_blocked?("overwrite")
//                   unconditionally while put_blob gates it behind the
//                   existing-blob branch, so block-list creates are refused
//                   where Put Blob creates are admitted. The phase records
//                   the typed refusal, then runs a degraded Put-Blob archive
//                   (creates admitted) to still measure the delta.
//   4 BACKPRESSURE— consumer archive deliberately slowed (30 ms/batch);
//                   sample producer-sent vs archived lag growth, then
//                   measure catch-up drain rate.
//
// Emits docs/jira/v26.10.14/bench/c3-eh-blob.jsonl records
// {lane:"c3", surface, op, n, ops_per_sec, errors, machine, ...extras}.
// Fail-closed: a phase that cannot complete records the failure and non-zero
// exit. Substrate is killed on exit (down after).
//
// Run: node scripts/bench/c3_eh_blob_archive.mjs
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { createRequire } from "node:module";
import { randomBytes } from "node:crypto";

const REPO = path.resolve(import.meta.dirname, "../..");
const JSONL = path.join(REPO, "docs/jira/v26.10.14/bench/c3-eh-blob.jsonl");
const LANE = "c3";
const SURFACE = "eh-blob-ts-sdk";
const AMQP_PORT = Number(process.env.C3_AMQP_PORT || 39680);
const EH_PORT = Number(process.env.C3_EH_PORT || 39681);
const ARM_PORT = Number(process.env.C3_ARM_PORT || 39682);
const EGRESS_PORT = Number(process.env.C3_EGRESS_PORT || 39683);
const ARM_TLS_PORT = Number(process.env.C3_ARM_TLS_PORT || 39684);
const POLL_DEADLINE_MS = 120_000;
const N_EVENTS = 2000;
const EVENT_BYTES = 1024;
const BATCH_EVENTS = 64;          // events per staged block
const COMMIT_BLOCKS = 8;          // 8 x 64 KiB = 512 KiB per committed blob
const EHUB = "c3-hub";
const ACCOUNT = "smaltacct";
const ACCOUNT_KEY = "smaltacct-key";
const EGRESS = `http://127.0.0.1:${EGRESS_PORT}`;

const { EventHubProducerClient, EventHubConsumerClient } = createRequire(
  path.join(REPO, "verification/ts/package.json"))("@azure/event-hubs");

const machine = {
  cpu: os.cpus()[0]?.model || "unknown",
  cores: os.cpus().length,
  ram_gb: Math.round(os.totalmem() / 1024 ** 3),
  node: process.version,
  darwin: os.type() + " " + os.release(),
};

const records = [];
function emit(op, n, ops_per_sec, extra = {}) {
  const rec = {
    lane: LANE, surface: SURFACE, op, n,
    ops_per_sec: Number(ops_per_sec.toFixed(2)),
    ...extra, machine,
  };
  records.push(rec);
  fs.appendFileSync(JSONL, JSON.stringify(rec) + "\n");
  console.log(`[c3] ${op}: n=${n} ops_per_sec=${rec.ops_per_sec} ` +
    Object.entries(extra).filter(([k]) => k !== "machine").map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(" "));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function percentile(v, p) {
  if (!v.length) return 0;
  const s = [...v].sort((a, b) => a - b);
  return Number(s[Math.round((p / 100) * (s.length - 1))].toFixed(3));
}

// ---------------------------------------------------------------------------
// Raw SharedKey-signed blob REST over ONE persistent keep-alive HTTP
// connection (node:http agent, maxSockets 1). Constraint discovered in run 3:
// the substrate's :smalt_blob_blocks ETS table is created by
// ensure_block_table/0 owned by the CALLING Bandit connection process — when
// that connection closes, the table (and every staged block) dies with it and
// the next request recreates it empty (witnessed: stage_block 500 "table
// identifier does not refer to an existing ETS table" + Put Block List 400
// InvalidBlockList). v26.10.15 substrate candidate. Riding a single live
// connection keeps the owner process alive across stage -> commit.
// ---------------------------------------------------------------------------
import http from "node:http";
const agent = new http.Agent({ keepAlive: true, keepAliveMsecs: 30_000, maxSockets: 1, maxFreeSockets: 1 });

function httpRequest(url, method, headers, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = http.request({
      host: u.hostname, port: u.port, path: u.pathname + u.search, method,
      agent, headers: {
        ...headers,
        host: u.host,
        // The substrate (Bandit) refuses chunked request bodies ("Malformed
        // chunked encoding request body" — also what breaks the SDK's
        // stageBlock); always send an explicit Content-Length.
        ...(body ? { "content-length": String(Buffer.byteLength(body)) } : {}),
      },
    }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, text: async () => Buffer.concat(chunks).toString("utf8") }));
      res.on("error", reject);
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

function signedFetch(url, method, extraHeaders = {}, body) {
  const u = new URL(url);
  const xms = Object.entries(extraHeaders)
    .filter(([k]) => k.toLowerCase().startsWith("x-ms-"))
    .sort(([a], [b]) => (a < b ? -1 : 1));
  const canonicalHeaders = xms.map(([k, v]) => `${k.toLowerCase()}:${v}\n`).join("");
  const canonicalResource =
    `/${ACCOUNT}${u.pathname}` +
    [...u.searchParams.entries()].map(([k, v]) => `\n${k.toLowerCase()}:${v}`).join("");
  const stringToSign = [
    method, "", "", body ? Buffer.byteLength(body) : "", "", "", "", "", "", "", "", "",
    canonicalHeaders + canonicalResource,
  ].join("\n");
  const sig = crypto.createHmac("sha256", Buffer.from(ACCOUNT_KEY, "utf8"))
    .update(stringToSign, "utf8").digest("base64");
  return httpRequest(url, method, {
    ...extraHeaders,
    "x-ms-date": new Date().toUTCString(),
    "x-ms-version": "2021-12-02",
    Authorization: `SharedKey ${ACCOUNT}:${sig}`,
  }, body);
}
const containerUrl = (c) => `${EGRESS}/${ACCOUNT}/${c}`;
const blobUrl = (c, b) => `${EGRESS}/${ACCOUNT}/${c}/${b}`;

async function putBlock(blob, blockId, body) {
  const r = await signedFetch(`${blob}?comp=block&blockid=${encodeURIComponent(blockId)}`,
    "PUT", { "x-ms-blob-type": "BlockBlob" }, body);
  if (r.status !== 201) throw new Error(`Put Block -> ${r.status} ${await r.text()}`);
}
async function commitBlockList(blob, blockIds) {
  const xml = `<?xml version="1.0" encoding="utf-8"?><BlockList>${blockIds.map((i) => `<Latest>${i}</Latest>`).join("")}</BlockList>`;
  const r = await signedFetch(`${blob}?comp=blocklist`, "PUT", {}, xml);
  return r.status;
}
async function putBlob(blob, body, contentType) {
  const r = await signedFetch(blob, "PUT", { "x-ms-blob-type": "BlockBlob", "x-ms-blob-content-type": contentType || "application/json" }, body);
  return r.status;
}
async function getBlob(blob) {
  const r = await fetch(blob, { headers: { Connection: "close", "x-ms-version": "2021-12-02" } });
  if (r.status !== 200) throw new Error(`Get Blob -> ${r.status}`);
  return Buffer.from(await r.arrayBuffer());
}
async function listBlobs(container, prefix) {
  const r = await signedFetch(`${containerUrl(container)}?comp=list&prefix=${encodeURIComponent(prefix)}&maxresults=5000`, "GET", {});
  if (r.status !== 200) throw new Error(`List Blobs -> ${r.status}`);
  const xml = await r.text();
  return [...xml.matchAll(/<Name>([^<]+)<\/Name>/g)].map((m) => m[1]).filter((n) => n !== container);
}

// ---------------------------------------------------------------------------
// Substrate boot — mirrors verification/ts/eventhubs.probe.mjs (private ports,
// MIX_ENV=test, random shared key). Kills the beam on exit.
// ---------------------------------------------------------------------------
let child = null;
async function bootSubstrate() {
  for (const p of [AMQP_PORT, EH_PORT, ARM_PORT, EGRESS_PORT, ARM_TLS_PORT]) {
    const free = await new Promise((resolve) => {
      const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1200 });
      s.once("connect", () => { s.destroy(); resolve(false); });
      s.once("error", () => resolve(true));
      s.once("timeout", () => { s.destroy(); resolve(true); });
    });
    if (!free) throw new Error(`port ${p} occupied — override C3_*_PORT or wait`);
  }
  const sharedKey = randomBytes(48).toString("base64");
  const bootEval = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP_PORT}")`,
    `Application.put_env(:smalt, :amqp_port, ${AMQP_PORT})`,
    `Application.put_env(:smalt, :event_hubs_port, ${EH_PORT})`,
    `Application.put_env(:smalt, :arm_port, ${ARM_PORT})`,
    `Application.put_env(:smalt, :egress_port, ${EGRESS_PORT})`,
    `Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT})`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
    `Process.sleep(:infinity)`,
  ].join("; ");
  const logPath = path.join(REPO, "verification/ts/.logs/c3-substrate.log");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const log = fs.createWriteStream(logPath, { flags: "w" });
  child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: { ...process.env, MIX_ENV: "test" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  child.stdout.pipe(log); child.stderr.pipe(log);
  const t0 = Date.now();
  for (;;) {
    const ups = await Promise.all([AMQP_PORT, EH_PORT, ARM_PORT, EGRESS_PORT, ARM_TLS_PORT]
      .map((p) => new Promise((resolve) => {
        const s = net.connect({ host: "127.0.0.1", port: p, total: 0, timeout: 1500 });
        s.once("connect", () => { s.destroy(); resolve(true); });
        s.once("error", () => resolve(false));
        s.once("timeout", () => { s.destroy(); resolve(false); });
      })));
    if (ups.every(Boolean)) break;
    if (Date.now() - t0 > POLL_DEADLINE_MS) {
      throw new Error(`substrate did not open ${AMQP_PORT}-${ARM_TLS_PORT} in ${POLL_DEADLINE_MS / 1000}s; log: ${logPath}`);
    }
    await sleep(500);
  }
  return sharedKey;
}
function downSubstrate() {
  if (!child) return;
  try {
    if (child.pid && child.exitCode === null) {
      try { process.kill(-child.pid, "SIGTERM"); } catch { child.kill("SIGTERM"); }
      const dl = Date.now() + 5000;
      const reap = setInterval(() => {
        if (child.exitCode !== null || Date.now() > dl) {
          try { if (child.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch { }
          clearInterval(reap);
        }
      }, 200);
    }
  } catch { /* gone */ }
}
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { downSubstrate(); process.exit(130); });
process.on("exit", () => {
  try { if (child?.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch { }
});

// ---------------------------------------------------------------------------
// Archiver — per-partition rolling block-blob writer.
// 64 events -> Put Block; every 8 staged blocks (512 KiB) -> Put Block List
// and roll to a fresh blob. mode "block" (default) or "put-blob" (degraded
// WORM path: one Put Blob create per 512 KiB chunk).
// ---------------------------------------------------------------------------
function makeArchiver(containerName, partitionId, runTag, { throttleMs = 0, mode = "block" } = {}) {
  let blobIdx = 0;
  let buf = [];
  let blocks = [];
  let blockEvents = [];
  let pendingCount = 0;
  let committed = 0, staged = 0, blobCommits = 0;
  let current = null;
  const lat = [];
  const blockIdOf = () => Buffer.from(
    `${partitionId}-${runTag}-${blobIdx}-${blocks.length}-${randomBytes(4).toString("hex")}`).toString("base64");
  const blobNameOf = () => `c3/${runTag}/partition-${partitionId}/chunk-${String(blobIdx).padStart(4, "0")}.jsonl`;

  async function newBlob() { current = blobUrl(containerName, blobNameOf()); blocks = []; blockEvents = []; }

  async function commit() {
    if (mode === "put-blob") {
      const body = Buffer.concat(blockBodies);
      const st = await putBlob(current, body);
      if (st !== 201) throw new Error(`Put Blob -> ${st}`);
    } else {
      if (!blocks.length) { await newBlob(); return; }
      const st = await commitBlockList(current, blocks);
      if (st !== 201) throw new Error(`Put Block List -> ${st} on ${current}`);
    }
    committed += blockEvents.reduce((s, n) => s + n, 0);
    blobCommits++;
    blocks = []; blockEvents = []; blockBodies = [];
    blobIdx++;
    await newBlob();
  }
  let blockBodies = [];
  async function flush(final = false) {
    if (!buf.length && !blocks.length) return;
    if (buf.length) {
      if (throttleMs) await sleep(throttleMs);
      const t0 = performance.now();
      const id = blockIdOf();
      const body = Buffer.concat(buf.map((e) => Buffer.from(JSON.stringify(e) + "\n")));
      if (mode === "block") await putBlock(current, id, body);
      blockBodies.push(body);
      lat.push(performance.now() - t0);
      blocks.push(id);
      blockEvents.push(buf.length);
      buf = [];
      staged += pendingCount;
      pendingCount = 0;
    }
    if (final || blocks.length >= COMMIT_BLOCKS) await commit();
  }
  return {
    async start() { await newBlob(); },
    async archive(event) {
      buf.push(event);
      pendingCount = buf.length;
      if (buf.length >= BATCH_EVENTS) await flush();
    },
    finish: () => flush(true),
    stats: () => ({
      committed, staged, blob_commits: blobCommits,
      p50_ms: percentile(lat, 50), p95_ms: percentile(lat, 95), p99_ms: percentile(lat, 99),
    }),
  };
}

// ---------------------------------------------------------------------------
// One full producer->consumer->archive pass.
// ---------------------------------------------------------------------------
async function runPass({ label, containerName, partitionIds, conn, archiverOpts = {} }) {
  const runTag = `${label}-${Date.now()}`;
  const archivers = new Map();
  const consumer = new EventHubConsumerClient(
    EventHubConsumerClient.defaultConsumerGroupName, conn,
    { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } });
  const subHandles = [];
  for (const pid of partitionIds) {
    const arch = makeArchiver(containerName, pid, runTag, archiverOpts);
    archivers.set(pid, arch);
    await arch.start();
    const sub = await consumer.subscribe(pid, {
      processEvents: async (events) => {
        for (const ev of events) {
          let body = ev.body;
          if (typeof body === "string") { try { body = JSON.parse(body); } catch { } }
          if (body && typeof body === "object" && body.run === runTag) {
            await arch.archive({ seq: ev.sequenceNumber, offset: ev.offset, enqueued: ev.enqueuedTimeUtc?.toISOString?.(), body });
          }
        }
      },
      processError: async (err) => {
        console.error(`[c3][partition ${pid}] processError: ${err?.name}: ${String(err?.message).slice(0, 200)}`);
      },
    }, { startPosition: { offset: "-1" }, maxWaitTimeInSeconds: 1 });
    subHandles.push(sub);
  }
  await sleep(1500); // subscriptions settle before the first send

  // producer: 2000 x 1 KiB, one event per createBatch/sendBatch, round-robin
  // partition pinning (the one-event-per-send contract; multi-event batches
  // drop events 2..N — Q-2).
  const producer = new EventHubProducerClient(conn,
    { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } });
  const samples = []; // {t, sent, archived}
  const pad = "x".repeat(EVENT_BYTES - 80);
  const sendStart = performance.now();
  let sent = 0;
  const sendLoop = (async () => {
    for (let i = 0; i < N_EVENTS; i++) {
      const pid = partitionIds[i % partitionIds.length];
      const body = { run: runTag, i, pid, pad };
      const batch = await producer.createBatch({ partitionId: pid, abortSignal: AbortSignal.timeout(20_000) });
      if (!batch.tryAdd({ body: JSON.stringify(body) })) throw new Error(`tryAdd failed at i=${i}`);
      await producer.sendBatch(batch, { abortSignal: AbortSignal.timeout(20_000) });
      sent++;
      // Paced producer: ~24 ms per 8 sends (~330 ev/s) matches the post-KD-18/
      // 19/20 witnessed producer class (323/s). Unpaced streaming was
      // witnessed in run 1 to trip the substrate EH consumer link with
      // {:bad_frame_body, :truncated} after "transfer when credit was 0" —
      // recorded as a v26.10.15 substrate candidate, not masked here.
      if (i % 8 === 7) await sleep(24);
      if (sent % 500 === 0) console.log(`[c3][${label}] sent ${sent}/${N_EVENTS}`);
    }
  })();

  const perPartition = Math.ceil(N_EVENTS / partitionIds.length);
  const sampleDeadline = performance.now() + 150_000;
  const sampling = (async () => {
    while (performance.now() < sampleDeadline) {
      const done = sent >= N_EVENTS && [...archivers.values()].every((a) => a.stats().committed + a.stats().staged >= perPartition);
      samples.push({
        t: performance.now() - sendStart,
        sent,
        archived: [...archivers.values()].reduce((s, a) => s + a.stats().committed + a.stats().staged, 0),
      });
      if (done) break;
      await sleep(250);
    }
  })();

  const drainDeadline = Date.now() + 90_000;
  await sendLoop;
  const sendMs = performance.now() - sendStart;
  while (Date.now() < drainDeadline) {
    const done = [...archivers.values()].every((a) => a.stats().committed + a.stats().staged >= perPartition);
    if (done) break;
    await sleep(200);
  }
  await Promise.all([...archivers.values()].map((a) => a.finish()));
  await sampling;

  const statsByPartition = Object.fromEntries([...archivers].map(([p, a]) => [p, a.stats()]));
  const totalArchived = Object.values(statsByPartition).reduce((s, st) => s + st.committed, 0);
  const archiveDurMs = performance.now() - sendStart;
  const eventsPerSec = totalArchived / (archiveDurMs / 1000);

  let maxLag = 0, lagAtSendEnd = 0;
  for (const s of samples) {
    const lag = s.sent - s.archived;
    if (lag > maxLag) maxLag = lag;
    lagAtSendEnd = lag;
  }
  await Promise.all(subHandles.map((h) => closeBounded(h)));
  await closeBounded(consumer);
  await closeBounded(producer);
  return { runTag, sent, totalArchived, statsByPartition, samples, sendMs, archiveDurMs, eventsPerSec, maxLag, lagAtSendEnd };
}

async function closeBounded(h, ms = 4000) {
  try {
    await Promise.race([
      Promise.resolve(h.close()).catch(() => { }),
      new Promise((r) => setTimeout(r, ms)),
    ]);
  } catch { }
}

// ---------------------------------------------------------------------------
// Ordering verification — download committed blobs, check per-partition
// sequence continuity (EH seq + body.i step 1, no gaps/dupes).
// ---------------------------------------------------------------------------
async function verifyOrdering(containerName, runTag, partitionIds) {
  const out = {};
  for (const pid of partitionIds) {
    const names = (await listBlobs(containerName, `c3/${runTag}/partition-${pid}/`)).sort();
    const seqs = [];
    const idx = [];
    for (const name of names) {
      const buf = await getBlob(blobUrl(containerName, name));
      for (const line of buf.toString("utf8").split("\n")) {
        if (!line.trim()) continue;
        const rec = JSON.parse(line);
        seqs.push(rec.seq); idx.push(rec.body.i);
      }
    }
    const expected = Math.ceil(N_EVENTS / partitionIds.length);
    const seqOk = seqs.length > 0 && seqs.every((s, k) => k === 0 || s === seqs[k - 1] + 1);
    const idxOk = idx.length > 0 && idx.every((v, k) => k === 0 || v === idx[k - 1] + 1);
    out[pid] = {
      blobs: names.length, events: seqs.length, expected,
      seq_continuous: seqOk, body_i_continuous: idxOk,
      first_seq: seqs[0], last_seq: seqs[seqs.length - 1],
      count_ok: seqs.length === expected,
    };
  }
  return out;
}

// ---------------------------------------------------------------------------
async function main() {
  const sharedKey = await bootSubstrate();
  console.log(`[c3] substrate up on ${AMQP_PORT}-${ARM_TLS_PORT}`);
  const conn =
    `Endpoint=sb://127.0.0.1:${EH_PORT};SharedAccessKeyName=RootManageSharedAccessKey;` +
    `SharedAccessKey=${sharedKey};EntityPath=${EHUB};UseDevelopmentEmulator=true`;

  // containers: mutable (x-ms-immutable-policy:false substrate extension) and
  // default-immutable (plain create -> WORM).
  const tag = Date.now();
  const mutName = `c3-mut-${tag}`;
  const immName = `c3-imm-${tag}`;
  {
    const r = await signedFetch(containerUrl(mutName), "PUT", { "x-ms-immutable-policy": "false" });
    if (r.status !== 201) throw new Error(`mutable container create -> ${r.status}`);
  }
  {
    const r = await signedFetch(containerUrl(immName), "PUT", {});
    if (r.status !== 201) throw new Error(`immutable container create -> ${r.status}`);
  }

  // partition discovery
  const disc = new EventHubProducerClient(conn, { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } });
  const props = await disc.getEventHubProperties({ abortSignal: AbortSignal.timeout(15_000) });
  const partitionIds = props.partitionIds.map(String);
  await closeBounded(disc);
  console.log(`[c3] hub partitions: ${JSON.stringify(partitionIds)}`);

  // ---- Phase 1: STREAM (mutable container) --------------------------------
  const p1 = await runPass({ label: "stream", containerName: mutName, partitionIds, conn });
  emit("stream-archive-e2e", p1.totalArchived, p1.eventsPerSec, {
    errors: p1.totalArchived === N_EVENTS ? 0 : 1,
    sent: p1.sent,
    send_ms: Math.round(p1.sendMs),
    send_events_per_sec: Number((p1.sent / (p1.sendMs / 1000)).toFixed(2)),
    blob_commits: Object.values(p1.statsByPartition).reduce((s, x) => s + x.blob_commits, 0),
    partitions: partitionIds.length,
    complete: p1.totalArchived === N_EVENTS,
  });

  // ---- Phase 2: ORDERING (verify the Phase-1 archive) ----------------------
  const order = await verifyOrdering(mutName, p1.runTag, partitionIds);
  const allOk = Object.values(order).every((o) => o.seq_continuous && o.body_i_continuous && o.count_ok);
  emit("ordering-verify", Object.values(order).reduce((s, o) => s + o.events, 0), 0, {
    errors: allOk ? 0 : 1, pass: allOk, per_partition: order,
  });
  if (!allOk) console.error(`[c3] ORDERING FAIL: ${JSON.stringify(order)}`);

  // ---- Phase 3: WORM (immutable container) ---------------------------------
  // First witnessed attempt: block-list path on the immutable container.
  let wormMode = "block";
  let wormBlocked = null;
  {
    const arch = makeArchiver(immName, partitionIds[0], `wormprobe-${tag}`, { mode: "block" });
    await arch.start();
    try {
      for (let i = 0; i < BATCH_EVENTS; i++) {
        await arch.archive({ seq: i, offset: "probe", enqueued: null, body: { run: `wormprobe-${tag}`, i, pid: partitionIds[0], pad: "probe" } });
      }
      await arch.finish();
    } catch (e) {
      wormBlocked = String(e?.message || e).slice(0, 300);
      console.error(`[c3] WORM block-list commit refused: ${wormBlocked}`);
    }
  }
  if (wormBlocked) {
    // Typed refusal recorded; degraded Put-Blob archive for the delta.
    emit("worm-commit-create-refused", 1, 0, { errors: 1, pass: false, error: wormBlocked });
    wormMode = "put-blob";
  }
  const p3 = await runPass({ label: "worm", containerName: immName, partitionIds, conn, archiverOpts: { mode: wormMode } });
  const deltaPct = Number((((p1.eventsPerSec - p3.eventsPerSec) / p1.eventsPerSec) * 100).toFixed(2));
  emit("worm-archive-e2e", p3.totalArchived, p3.eventsPerSec, {
    errors: p3.totalArchived === N_EVENTS ? 0 : 1,
    sent: p3.sent,
    send_ms: Math.round(p3.sendMs),
    send_events_per_sec: Number((p3.sent / (p3.sendMs / 1000)).toFixed(2)),
    blob_commits: Object.values(p3.statsByPartition).reduce((s, x) => s + x.blob_commits, 0),
    mode: wormMode,
    degraded: wormBlocked != null,
    archive_rate_delta_pct_vs_mutable: deltaPct,
    complete: p3.totalArchived === N_EVENTS,
  });

  // WORM enforcement witness: overwrite in the immutable container -> 409.
  {
    const name = `c3/${p3.runTag}/partition-${partitionIds[0]}/chunk-0000.jsonl`;
    const st = await putBlob(blobUrl(immName, name), Buffer.from("overwrite-probe"));
    const immOk = st === 409;
    emit("worm-overwrite-409", 1, 0, { errors: immOk ? 0 : 1, status: st, pass: immOk });
    if (!immOk) console.error(`[c3] WORM overwrite expected 409, got ${st}`);
  }

  // ---- Phase 4: BACKPRESSURE ----------------------------------------------
  const bp = await runPass({ label: "backpressure", containerName: mutName, partitionIds, conn, archiverOpts: { throttleMs: 30 } });
  emit("backpressure-lag", bp.sent, 0, {
    errors: 0, samples: bp.samples.length, max_lag_events: bp.maxLag,
    lag_at_send_end: bp.lagAtSendEnd, throttle_ms_per_batch: 30,
  });
  const drainMs = bp.archiveDurMs - bp.sendMs;
  emit("backpressure-catchup", bp.totalArchived, bp.totalArchived / (drainMs / 1000), {
    errors: 0, drain_ms: Math.round(drainMs), max_lag_events: bp.maxLag,
    pass: bp.totalArchived === N_EVENTS,
  });

  // ---- summary table -------------------------------------------------------
  console.log("\n=== C-3 archive table (events/s end-to-end, 2000 x 1 KiB) ===");
  for (const r of records.filter((x) => x.op.endsWith("archive-e2e"))) {
    console.log(`${r.op.padEnd(20)} n=${String(r.n).padEnd(5)} ev/s=${String(r.ops_per_sec).padEnd(8)} send_ev/s=${r.send_events_per_sec} commits=${r.blob_commits} delta=${r.archive_rate_delta_pct_vs_mutable ?? "-"}%${r.degraded ? " (degraded put-blob)" : ""}`);
  }
  const failed = records.some((r) => r.errors > 0 || r.pass === false);
  console.log(`ordering=${records.find((r) => r.op === "ordering-verify")?.pass} worm409=${records.find((r) => r.op === "worm-overwrite-409")?.pass} catchup=${records.find((r) => r.op === "backpressure-catchup")?.pass} -> exit ${failed ? 1 : 0} (worm-create-refused finding included)`);
  downSubstrate();
  agent.destroy(); // BK-N7 teardown: keep-alive sockets hold the event loop
  process.exitCode = failed ? 1 : 0;
}

main().catch(async (e) => {
  console.error(`[c3] harness error: ${e?.stack || e}`);
  downSubstrate();
  agent.destroy(); // BK-N7 teardown
  process.exitCode = 3;
});
