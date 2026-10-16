#!/usr/bin/env node
// c3_eh_blob_archive.mjs — bench lane C-3: Event Hubs -> Blob streaming
// archive (the EH Capture pattern) via the REAL TypeScript SDKs
// (@azure/event-hubs + @azure/storage-blob from test/sdk-full) against the
// live smalt substrate on a private port block (docs/DEV_LOOP.md private
// 39000-39999: 39680-39684, disjoint from the ts-eh-probe 39690-39694 block
// and from b1..b12's 39010-39125 formula blocks).
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
//   3 WORM        — same flow into a default-immutable container (creates
//                   admitted, overwrites 409) — archive-rate delta vs mutable.
//   4 BACKPRESSURE— consumer archive deliberately slowed; sample producer-sent
//                   vs consumer-archived lag growth, then unthrottle and
//                   measure catch-up rate.
//
// Emits docs/jira/v26.10.14/bench/c3-eh-blob.jsonl records
// {lane:"c3", surface, op, n, ops_per_sec, p50_ms.., errors, machine, extra}.
// Fail-closed: a phase that cannot complete records the failure and non-zero
// exit. Substrate is killed on exit (down after).
//
// Run: node scripts/bench/c3_eh_blob_archive.mjs
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
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

const { EventHubProducerClient, EventHubConsumerClient } = createRequire(
  path.join(REPO, "test/sdk-full/package.json"))("@azure/event-hubs");
const { BlobServiceClient, StorageSharedKeyCredential } = createRequire(
  path.join(REPO, "test/sdk-full/package.json"))("@azure/storage-blob");

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

// ---------------------------------------------------------------------------
// Substrate boot — mirrors test/sdk-full/eventhubs.probe.mjs (private ports,
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
  const logPath = path.join(REPO, "test/sdk-full/.logs/c3-substrate.log");
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
        const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1500 });
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
    }
  } catch { /* gone */ }
  const dl = Date.now() + 5000;
  const reap = setInterval(() => {
    if (child.exitCode !== null || Date.now() > dl) {
      try { if (child.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch { }
      clearInterval(reap);
    }
  }, 200);
}
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { downSubstrate(); process.exit(130); });
process.on("exit", () => {
  try { if (child?.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch { }
});

// ---------------------------------------------------------------------------
// Archiver — per-partition rolling block-blob writer.
// 64 events -> stageBlock; every 8 staged blocks (512 KiB) -> commitBlockList
// and roll to a fresh blob. Returns {archive(event), finish(), stats}.
// ---------------------------------------------------------------------------
function makeArchiver(containerClient, partitionId, runTag, throttleMs = 0) {
  let blobIdx = 0;
  let buf = [];
  let blocks = [];
  let committed = 0, staged = 0, blobCommits = 0;
  let current = null;
  const lat = [];
  const blockIdOf = () => Buffer.from(
    `${partitionId}-${runTag}-${blobIdx}-${blocks.length}-${randomBytes(4).toString("hex")}`).toString("base64");

  async function newBlob() {
    current = containerClient.getBlockBlobClient(
      `c3/${runTag}/partition-${partitionId}/chunk-${String(blobIdx).padStart(4, "0")}.jsonl`);
    blocks = [];
  }
  async function commit() {
    if (!blocks.length) { await newBlob(); return; }
    const t0 = performance.now();
    await current.commitBlockList(blocks, { abortSignal: AbortSignal.timeout(30_000) });
    lat.push(performance.now() - t0);
    committed += blocks.length * BATCH_EVENTS;
    blobCommits++;
    blocks = [];
    blobIdx++;
    await newBlob();
  }
  async function flush(final = false) {
    if (!buf.length && !blocks.length) return;
    if (buf.length) {
      if (throttleMs) await sleep(throttleMs);
      const t0 = performance.now();
      const id = blockIdOf();
      const body = Buffer.concat(buf.map((e) => Buffer.from(JSON.stringify(e) + "\n")));
      await current.stageBlock(id, body, { abortSignal: AbortSignal.timeout(30_000) });
      lat.push(performance.now() - t0);
      blocks.push(id);
      buf = [];
      staged += BATCH_EVENTS;
    }
    if (final || blocks.length >= COMMIT_BLOCKS) await commit();
  }
  return {
    async start() { await newBlob(); },
    async archive(event) {
      buf.push(event);
      if (buf.length >= BATCH_EVENTS) await flush();
    },
    finish: () => flush(true),
    stats: () => ({
      committed, staged, blob_commits: blobCommits,
      p50_ms: percentile(lat, 50), p95_ms: percentile(lat, 95), p99_ms: percentile(lat, 99),
    }),
  };
}
function percentile(v, p) {
  if (!v.length) return 0;
  const s = [...v].sort((a, b) => a - b);
  return Number(s[Math.round((p / 100) * (s.length - 1))].toFixed(3));
}

// ---------------------------------------------------------------------------
// One full producer->consumer->archive pass. Returns per-partition results.
// partitionIds: partition list; container: destination; opts {throttleMs}.
// ---------------------------------------------------------------------------
async function runPass({ label, container, partitionIds, conn, throttleMs = 0 }) {
  const runTag = `${label}-${Date.now()}`;
  const archivers = new Map();
  const received = new Map(partitionIds.map((p) => [p, []]));
  const consumer = new EventHubConsumerClient(
    EventHubConsumerClient.defaultConsumerGroupName, conn,
    { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } });
  const subHandles = [];
  for (const pid of partitionIds) {
    const arch = makeArchiver(container, pid, runTag, throttleMs);
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
          received.get(pid).push(1);
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
  const sentTimes = [];
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
      sentTimes.push(performance.now());
      if (sent % 500 === 0) console.log(`[c3][${label}] sent ${sent}/${N_EVENTS}`);
    }
  })();

  // sampler: producer-sent vs events-archived-to-committed-blobs
  const sampling = (async () => {
    while (sent < N_EVENTS || ![...archivers.values()].every((a) => a.stats().committed + a.stats().staged >= N_EVENTS / partitionIds.length)) {
      samples.push({
        t: performance.now() - sendStart,
        sent,
        archived: [...archivers.values()].reduce((s, a) => s + a.stats().committed + a.stats().staged, 0),
      });
      await sleep(250);
    }
  })();

  // drain: wait until every partition archived all its events (final commit
  // happens below), bounded.
  const drainDeadline = Date.now() + 90_000;
  await sendLoop;
  const sendMs = performance.now() - sendStart;
  while (Date.now() < drainDeadline) {
    const done = [...archivers.values()].every((a) => a.stats().committed + a.stats().staged >= Math.ceil(N_EVENTS / partitionIds.length));
    if (done) break;
    await sleep(200);
  }
  await Promise.all([...archivers.values()].map((a) => a.finish()));
  await sampling;

  const statsByPartition = Object.fromEntries([...archivers].map(([p, a]) => [p, a.stats()]));
  const totalArchived = Object.values(statsByPartition).reduce((s, st) => s + st.committed, 0);
  const archiveDurMs = performance.now() - sendStart;
  const eventsPerSec = totalArchived / (archiveDurMs / 1000);

  // lag analysis (only meaningful when throttleMs > 0)
  let maxLag = 0, lagAtSendEnd = 0;
  for (const s of samples) {
    const lag = s.sent - s.archived;
    if (lag > maxLag) maxLag = lag;
    lagAtSendEnd = lag;
  }
  await Promise.all(subHandles.map((h) => closeBounded(h)));
  await closeBounded(consumer);
  await closeBounded(producer);
  return { runTag, sent, totalArchived, statsByPartition, samples, sendMs, archiveDurMs, eventsPerSec, maxLag, lagAtSendEnd, receivedCounts: Object.fromEntries(received) };
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
async function verifyOrdering(container, runTag, partitionIds) {
  const out = {};
  for (const pid of partitionIds) {
    const names = [];
    for await (const b of container.listBlobsFlat({ prefix: `c3/${runTag}/partition-${pid}/` })) names.push(b.name);
    names.sort();
    const seqs = [];
    const idx = [];
    for (const name of names) {
      const bc = container.getBlockBlobClient(name);
      const dl = await bc.download(undefined, undefined, { abortSignal: AbortSignal.timeout(30_000) });
      const chunks = [];
      for await (const c of dl.readableStreamBody) chunks.push(Buffer.from(c));
      for (const line of Buffer.concat(chunks).toString("utf8").split("\n")) {
        if (!line.trim()) continue;
        const rec = JSON.parse(line);
        seqs.push(rec.seq); idx.push(rec.body.i);
      }
    }
    const seqOk = seqs.length > 0 && seqs.every((s, k) => k === 0 || s === seqs[k - 1] + 1);
    const idxOk = idx.length > 0 && idx.every((v, k) => k === 0 || v === idx[k - 1] + 1);
    const expected = Math.ceil(N_EVENTS / partitionIds.length);
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
  const service = new BlobServiceClient(
    `http://127.0.0.1:${EGRESS_PORT}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY));
  const E2 = (t) => ({ abortSignal: AbortSignal.timeout(30_000) });

  // containers: mutable (x-ms-immutable-policy:false extension header) and
  // default-immutable (SDK create -> WORM).
  const mutTag = Date.now();
  const mut = service.getContainerClient(`c3-mut-${mutTag}`);
  {
    const res = await fetch(`${mut.url}`, {
      method: "PUT",
      headers: { "x-ms-version": "2021-12-02", "x-ms-immutable-policy": "false" },
      signal: AbortSignal.timeout(30_000),
    });
    if (res.status !== 201) throw new Error(`mutable container create -> ${res.status}`);
  }
  const imm = service.getContainerClient(`c3-imm-${mutTag}`);
  await imm.create(E2());

  // partition discovery
  const disc = new EventHubProducerClient(conn, { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } });
  const props = await disc.getEventHubProperties({ abortSignal: AbortSignal.timeout(15_000) });
  const partitionIds = props.partitionIds.map(String);
  await closeBounded(disc);
  console.log(`[c3] hub partitions: ${JSON.stringify(partitionIds)}`);
  const p50 = (arr) => percentile(arr, 50);

  // ---- Phase 1: STREAM (mutable container) --------------------------------
  const p1 = await runPass({ label: "stream", container: mut, partitionIds, conn });
  emit("stream-archive-e2e", p1.totalArchived, p1.eventsPerSec, {
    errors: 0, sent: p1.sent, send_ms: Math.round(p1.sendMs),
    send_events_per_sec: Number((p1.sent / (p1.sendMs / 1000)).toFixed(2)),
    blob_commits: Object.values(p1.statsByPartition).reduce((s, x) => s + x.blob_commits, 0),
    partitions: partitionIds.length,
    p50_block_ms: p50(Object.values(p1.statsByPartition).flatMap((s) => [s.p50_ms])),
  });
  const sendP1 = p1.send_events_per_sec_note = null;

  // ---- Phase 2: ORDERING (verify the Phase-1 archive) ----------------------
  const order = await verifyOrdering(mut, p1.runTag, partitionIds);
  const allOk = Object.values(order).every((o) => o.seq_continuous && o.body_i_continuous && o.count_ok);
  emit("ordering-verify", Object.values(order).reduce((s, o) => s + o.events, 0), 0, {
    errors: allOk ? 0 : 1, per_partition: order, pass: allOk,
  });
  if (!allOk) console.error(`[c3] ORDERING FAIL: ${JSON.stringify(order)}`);

  // ---- Phase 3: WORM (immutable container) ---------------------------------
  const p3 = await runPass({ label: "worm", container: imm, partitionIds, conn });
  const deltaPct = Number((((p1.eventsPerSec - p3.eventsPerSec) / p1.eventsPerSec) * 100).toFixed(2));
  emit("worm-archive-e2e", p3.totalArchived, p3.eventsPerSec, {
    errors: 0, sent: p3.sent, send_ms: Math.round(p3.sendMs),
    send_events_per_sec: Number((p3.sent / (p3.sendMs / 1000)).toFixed(2)),
    blob_commits: Object.values(p3.statsByPartition).reduce((s, x) => s + x.blob_commits, 0),
    archive_rate_delta_pct_vs_mutable: deltaPct,
  });

  // WORM enforcement witness: overwrite in the immutable container -> 409.
  {
    const immBlob = imm.getBlockBlobClient(`c3/${p3.runTag}/partition-${partitionIds[0]}/chunk-0000.jsonl`);
    let status = null;
    try {
      await immBlob.upload(Buffer.from("overwrite-probe"), 15, E2());
      status = 201;
    } catch (e) { status = e.statusCode || (e._response?.status) || null; }
    const immOk = status === 409;
    emit("worm-overwrite-409", 1, 0, { errors: immOk ? 0 : 1, status, pass: immOk });
    if (!immOk) console.error(`[c3] WORM overwrite expected 409, got ${status}`);
  }

  // ---- Phase 4: BACKPRESSURE ----------------------------------------------
  const bp = await runPass({ label: "backpressure", container: mut, partitionIds, conn, throttleMs: 30 });
  const lagSamples = bp.samples.length;
  emit("backpressure-lag", bp.sent, 0, {
    errors: 0, samples: lagSamples, max_lag_events: bp.maxLag,
    lag_at_send_end: bp.lagAtSendEnd, throttle_ms_per_batch: 30,
  });
  // catch-up: archived-minus-acked slope after send end is already inside
  // runPass's samples; catch-up rate = total archived / drain duration after
  // send end.
  const drainMs = bp.archiveDurMs - bp.sendMs;
  emit("backpressure-catchup", bp.totalArchived, bp.totalArchived / (drainMs / 1000), {
    errors: 0, drain_ms: Math.round(drainMs), max_lag_events: bp.maxLag,
    pass: bp.totalArchived === N_EVENTS,
  });

  // ---- summary table -------------------------------------------------------
  console.log("\n=== C-3 archive table (events/s end-to-end) ===");
  for (const r of records.filter((x) => x.op.endsWith("archive-e2e"))) {
    console.log(`${r.op.padEnd(22)} n=${String(r.n).padEnd(5)} ev/s=${String(r.ops_per_sec).padEnd(8)} send_ev/s=${r.send_events_per_sec} commits=${r.blob_commits} delta=${r.archive_rate_delta_pct_vs_mutable ?? "-"}%`);
  }
  console.log(`ordering pass=${allOk}  worm-409 pass=${records.find((r) => r.op === "worm-overwrite-409")?.pass}  catchup pass=${records.find((r) => r.op === "backpressure-catchup")?.pass}`);
  downSubstrate();
  const failed = records.some((r) => r.errors > 0 || r.pass === false);
  process.exitCode = failed ? 1 : 0;
}

main().catch(async (e) => {
  console.error(`[c3] harness error: ${e?.stack || e}`);
  downSubstrate();
  process.exitCode = 3;
});
