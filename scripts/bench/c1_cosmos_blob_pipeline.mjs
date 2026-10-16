// c1_cosmos_blob_pipeline.mjs — cross-product bench lane C-1: Cosmos<->Blob ETL
// pipeline (ingest -> transform -> archive) against the live smalt substrate.
//
// Boot: scripts/bench/lib.sh bench_boot c1 (port block 39010..39015; cosmos and
// blob both ride the egress/data plane, base+1 = 39011 — same shape as lanes
// b2/b3). Auth shapes mirror b3_cosmos_ts.mjs (CosmosClient master key) and
// b2_blob_ts.mjs / b2b_blob_hdr.mjs (StorageSharedKeyCredential, account
// "smaltacct" / "smaltacct-key", plain-HTTP egress; container create + legal
// hold via the raw-fetch idiom b2b uses).
//
// Phases, all measured end-to-end, one JSONL row each:
//   (1) INGEST     500 docs x 2 KiB upserted to Cosmos (fresh ids: the
//                  substrate 409s upsert-of-existing, KD-36)      -> docs/s
//   (2) TRANSFORM  continuation walk (SELECT * FROM c, fetchNext pages of
//                  100) + JSON transform of every doc               -> docs/s
//   (3) ARCHIVE    transformed batches packed to 64 KiB block blobs,
//                  5 rounds of the corpus (~90 blobs)               -> blobs/s + MB/s
//   (4) COMPOSITE  sequential 30 s ingest-only + 30 s archive-only
//                  baselines, then 60 s ingest+archive CONCURRENT.
//                  Interference delta = composite vs sequential rate and
//                  cosmos p50/p95 shift under blob load.
//   (5) WORM       archive into a container with legal hold (create-path
//                  law: new-blob writes still admitted) and an overwrite
//                  attempt that must 409 ContainerLocked mid-pipeline.
//
// 0-error discipline: every failure is recorded (errors[] + per-row error
// counts), never ignored; the expected-409 WORM overwrite is an assertion, not
// an error. Machine spec embedded per row via C1_MACHINE (bench_machine_spec).
import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(path.join(ROOT, "test/sdk-full/package.json"));
const { BlobServiceClient, StorageSharedKeyCredential } = require("@azure/storage-blob");
const { CosmosClient } = await import(path.join(ROOT, "test/sdk-full/node_modules/@azure/cosmos/dist/esm/index.js"));

const EP = process.env.C1_ENDPOINT ?? "http://127.0.0.1:39011";
const OUT = process.env.C1_OUT ?? path.join(ROOT, "docs/jira/v26.10.14/bench/c1-cosmos-blob.jsonl");
const MACHINE = process.env.C1_MACHINE ?? "unknown";
const TAG = Date.now();

const INGEST_DOCS = 500;
const DOC_BYTES = 2048;
const PAGE_SIZE = 100;
const ARCHIVE_ROUNDS = 5;
const SEQ_WINDOW_MS = 30_000;
const COMPOSITE_WINDOW_MS = 60_000;
const WARM_UPSERTS = 25;
const WARM_PUTS = 10;
const WORM_BLOBS = 10;

const ACCOUNT = "smaltacct";
const ACCOUNT_KEY = "smaltacct-key";
const DB_ID = `c1db-${TAG}`;

const log = (...a) => console.log(new Date().toISOString(), ...a);

// ---------------------------------------------------------------------------
// errors + rows
// ---------------------------------------------------------------------------
const errors = [];
let errCount = 0;
const noteErr = (op, e) => {
  errCount++;
  if (errors.length < 40)
    errors.push({ op, code: e?.code, status: e?.statusCode, msg: String(e?.message ?? e).slice(0, 200) });
};

function pct(v, p) {
  const s = [...v].sort((a, b) => a - b);
  return s[Math.round((p / 100) * (s.length - 1))];
}

function emit(row) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify({ lane: "c1", ...row, machine: MACHINE }) + "\n");
  console.log("ROW " + JSON.stringify({ op: row.op, n: row.n, ops_per_sec: row.ops_per_sec, p50: row.p50_ms, p95: row.p95_ms, p99: row.p99_ms, mb_per_sec: row.mb_per_sec ?? null, errors: row.errors }));
}

function summarize(op, surface, n, wallMs, lat, extra = {}) {
  const opsPerSec = +(n / (wallMs / 1000)).toFixed(2);
  const row = {
    surface, op, n, ops_per_sec: opsPerSec,
    p50_ms: +pct(lat, 50).toFixed(3), p95_ms: +pct(lat, 95).toFixed(3), p99_ms: +pct(lat, 99).toFixed(3),
    errors: extra._errDelta ?? 0, ...extra,
  };
  delete row._errDelta;
  emit(row);
  return row;
}

// per-phase error snapshot: capture before the phase, pass as _errDelta after
const errSnap = () => errCount;
const errDelta = (snap) => ({ _errDelta: errCount - snap });

// ---------------------------------------------------------------------------
// clients
// ---------------------------------------------------------------------------
const cosmos = new CosmosClient({
  endpoint: EP,
  key: crypto.randomBytes(32).toString("hex"),
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});
const service = new BlobServiceClient(`${EP}/${ACCOUNT}`, new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY));
const to = () => ({ abortSignal: AbortSignal.timeout(60_000) });

function makeDoc(i, bytes = DOC_BYTES) {
  return {
    id: `c1-ing-${TAG}-${i}`,
    pk: `part-${i % 10}`,
    i,
    src: "c1-etl",
    payload: "x".repeat(bytes),
  };
}

async function putBlob(container, name, buf) {
  const t0 = performance.now();
  try {
    await container.getBlockBlobClient(name).upload(buf, buf.length, to());
  } catch (e) {
    noteErr("archive-put", e);
  }
  return performance.now() - t0;
}

// ---------------------------------------------------------------------------
// (1) INGEST — 500 x 2 KiB upserts
// ---------------------------------------------------------------------------
async function phaseIngest(container, nDocs = INGEST_DOCS, prefix = `c1-ing-${TAG}`) {
  const snap = errSnap();
  const lat = [];
  let ok = 0;
  const t0 = performance.now();
  for (let i = 0; i < nDocs; i++) {
    const t1 = performance.now();
    try {
      await container.items.upsert(makeDoc(i, DOC_BYTES));
      ok++;
    } catch (e) { noteErr("ingest-upsert", e); }
    lat.push(performance.now() - t1);
  }
  const wall = performance.now() - t0;
  if (ok !== nDocs) noteErr("ingest-shortfall", { message: `ingested ${ok}/${nDocs}` });
  return summarize("ingest-2kib-upsert", "cosmos-ts", ok, wall, lat, errDelta(snap));
}

// ---------------------------------------------------------------------------
// (2) TRANSFORM — continuation walk + JSON transform
// ---------------------------------------------------------------------------
async function phaseTransform(container) {
  const snap = errSnap();
  const pageMs = [];
  const t0 = performance.now();
  let docs = 0;
  let pages = 0;
  const transformed = [];
  const iterator = container.items.query("SELECT * FROM c", { maxItemCount: PAGE_SIZE });
  for (;;) {
    const tp = performance.now();
    try {
      const resp = await iterator.fetchNext();
      pages++;
      for (const d of resp.resources) {
        transformed.push(JSON.stringify({ id: d.id, i: d.i, at: "c1-transform", len: d.payload?.length ?? 0 }));
      }
      docs += resp.resources.length;
      pageMs.push(performance.now() - tp);
      if (!resp.continuationToken) break;
    } catch (e) {
      noteErr("transform-walk", e);
      break;
    }
  }
  const wall = performance.now() - t0;
  return { row: summarize("transform-continuation-walk", "cosmos-ts", docs, wall, pageMs, errDelta(snap)), transformed };
}

// ---------------------------------------------------------------------------
// (3) ARCHIVE — transformed batches as 64 KiB block blobs
// ---------------------------------------------------------------------------
async function phaseArchive(container, transformed) {
  const snap = errSnap();
  // pack transformed docs into batches capped at 64 KiB AND 25 docs (so the
  // 500-doc corpus yields ~20 batches per round — enough blob samples)
  const batches = [];
  let cur = [], curLen = 0;
  for (const line of transformed) {
    cur.push(line); curLen += line.length + 1;
    if (curLen >= 60_000 || cur.length >= 25) { batches.push(cur); cur = []; curLen = 0; }
  }
  if (cur.length) batches.push(cur);
  const lat = [];
  let bytes = 0;
  const t0 = performance.now();
  for (let r = 0; r < ARCHIVE_ROUNDS; r++) {
    for (let b = 0; b < batches.length; b++) {
      let body = Buffer.from(batches[b].join("\n") + "\n", "utf8");
      if (body.length > 65536) body = body.subarray(0, 65536);
      const padded = Buffer.concat([body, Buffer.alloc(65536 - body.length, 0x20)]);
      lat.push(await putBlob(container, `c1-archive-${TAG}-r${r}-b${b}`, padded));
      bytes += 65536;
      if (errCount > snap) return summarize("archive-64kib-put", "blob-ts", lat.length, performance.now() - t0, lat, { mb_per_sec: null, ...errDelta(snap) });
    }
  }
  const wall = performance.now() - t0;
  const mb = bytes / (1024 * 1024);
  return summarize("archive-64kib-put", "blob-ts", lat.length, wall, lat, { mb_per_sec: +(mb / (wall / 1000)).toFixed(2), batches_per_round: batches.length, ...errDelta(snap) });
}

// ---------------------------------------------------------------------------
// (4) COMPOSITE — sequential baselines then 60 s concurrent
// ---------------------------------------------------------------------------
async function runIngestLoop(container, deadline, lat, mkId) {
  let ops = 0;
  let i = 0;
  while (Date.now() < deadline) {
    const t1 = performance.now();
    try {
      await container.items.upsert({ id: mkId(i), pk: `part-${i % 10}`, i, payload: "x".repeat(DOC_BYTES) });
      ops++;
    } catch (e) { noteErr("composite-ingest", e); }
    lat.push(performance.now() - t1);
    i++;
  }
  return ops;
}

async function runArchiveLoop(container, deadline, lat, prefix) {
  const payload = crypto.randomBytes(65536);
  let n = 0;
  while (Date.now() < deadline) {
    const t1 = performance.now();
    try {
      await container.getBlockBlobClient(`${prefix}-${n}`).upload(payload, 65536, to());
      n++;
    } catch (e) { noteErr("composite-archive", e); }
    lat.push(performance.now() - t1);
  }
  return n;
}

async function phaseComposite(etlContainer, archiveContainer) {
  const snap = errSnap();
  const results = {};
  const tag = Date.now();

  // sequential baselines (30 s each, also serves as composite warmup)
  const ingLat = [], archLat = [];
  let d = Date.now() + SEQ_WINDOW_MS;
  const ingOps = await runIngestLoop(etlContainer, d, ingLat, (i) => `c1-seq-${tag}-${i}`);
  results["seq-ingest"] = summarize("composite-seq-ingest-2kib", "cosmos-ts", ingOps, SEQ_WINDOW_MS, ingLat, errDelta(snap));

  d = Date.now() + SEQ_WINDOW_MS;
  const archOps = await runArchiveLoop(archiveContainer, d, archLat, `c1-seq-arch-${tag}`);
  results["seq-archive"] = summarize("composite-seq-archive-64kib", "blob-ts", archOps, SEQ_WINDOW_MS, archLat, { mb_per_sec: +((archOps * 65536 / (1024 * 1024)) / (SEQ_WINDOW_MS / 1000)).toFixed(2), ...errDelta(snap) });

  // 60 s concurrent — DISTINCT blob names from the seq window (containers on
  // this substrate are immutable-by-default; reusing a name is a 409)
  const cIngLat = [], cArchLat = [];
  const deadline = Date.now() + COMPOSITE_WINDOW_MS;
  const [cIngOps, cArchOps] = await Promise.all([
    runIngestLoop(etlContainer, deadline, cIngLat, (i) => `c1-con-${tag}-${i}`),
    runArchiveLoop(archiveContainer, deadline, cArchLat, `c1-con-arch-${tag}`),
  ]);
  const compositeOps = cIngOps + cArchOps;
  results["composite"] = summarize("composite-ingest-plus-archive", "cosmos+blob", compositeOps, COMPOSITE_WINDOW_MS, [...cIngLat, ...cArchLat], {
    mb_per_sec: +((cArchOps * 65536 / (1024 * 1024)) / (COMPOSITE_WINDOW_MS / 1000)).toFixed(2),
    ingest_ops_per_sec: +(cIngOps / (COMPOSITE_WINDOW_MS / 1000)).toFixed(2),
    archive_ops_per_sec: +(cArchOps / (COMPOSITE_WINDOW_MS / 1000)).toFixed(2),
    ...errDelta(snap),
  });
  return { results, cIngLat, cArchLat };
}

// ---------------------------------------------------------------------------
// (5) WORM — legal hold: create-path admitted, overwrite 409
// ---------------------------------------------------------------------------
async function phaseWorm(service, tag) {
  const snap = errSnap();
  const cname = `c1-worm-${tag}`;
  const wormContainer = service.getContainerClient(cname);
  await wormContainer.create({ abortSignal: AbortSignal.timeout(30_000) });
  // legal hold via the raw-fetch idiom (b2b_blob_hdr.mjs) — SDK ContainerClient
  // does not expose ?comp=legalhold
  const res = await fetch(`${wormContainer.url}?comp=legalhold`, {
    method: "PUT",
    headers: { "x-ms-version": "2021-12-02", "x-ms-legal-hold": "true" },
    signal: AbortSignal.timeout(30_000),
  });
  if (res.status !== 200) {
    noteErr("worm-legalhold-set", { message: `status ${res.status}: ${(await res.text()).slice(0, 150)}` });
    return { hold: false };
  }
  log("worm legal hold set:", cname);

  // archive: create-path — 10 fresh-blob writes must all be admitted
  const payload = crypto.randomBytes(65536);
  let admitted = 0;
  const lat = [];
  for (let i = 0; i < WORM_BLOBS; i++) {
    const t1 = performance.now();
    try {
      await wormContainer.getBlockBlobClient(`${cname}-${i}`).upload(payload, 65536, to());
      admitted++;
    } catch (e) { noteErr("worm-create", e); }
    lat.push(performance.now() - t1);
  }

  // overwrite attempt: must 409 ContainerLocked mid-pipeline
  let overwriteStatus = 0;
  try {
    await wormContainer.getBlockBlobClient(`${cname}-${0}`).upload(crypto.randomBytes(65536), 65536, to());
    overwriteStatus = 200; // write went through — create-path law violated
  } catch (e) {
    overwriteStatus = e?.statusCode ?? e?.code ?? 0;
    if (overwriteStatus !== 409) noteErr("worm-overwrite-unexpected", e);
  }

  summarize("worm-archive-under-legal-hold", "blob-ts-worm", admitted, lat.reduce((a, b) => a + b, 0), lat, {
    mb_per_sec: null,
    legal_hold_admitted: admitted === WORM_BLOBS,
    overwrite_status: overwriteStatus,
    overwrite_409: overwriteStatus === 409,
    ...errDelta(snap),
  });

  // cleanup: clear the hold so the lane-private container can be removed
  const clear = await fetch(`${wormContainer.url}?comp=legalhold`, {
    method: "PUT",
    headers: { "x-ms-version": "2021-12-10", "x-ms-legal-hold": "false" },
    signal: AbortSignal.timeout(30_000),
  });
  if (clear.status === 200) {
    try { await wormContainer.delete({ abortSignal: AbortSignal.timeout(30_000) }); } catch (e) { log("worm container delete failed:", e?.statusCode ?? e?.message); }
  } else {
    log("worm legal-hold clear failed:", clear.status, "(container left in place)");
  }
  return { hold: true, admitted, overwriteStatus };
}

// ---------------------------------------------------------------------------
async function main() {
  log("c1 start. endpoint", EP, "tag", TAG);
  const cosmosMeta = JSON.parse(fs.readFileSync(path.join(ROOT, "test/sdk-full/node_modules/@azure/cosmos/package.json"), "utf8")).version;
  const blobMeta = JSON.parse(fs.readFileSync(path.join(ROOT, "test/sdk-full/node_modules/@azure/storage-blob/package.json"), "utf8")).version;
  log("meta", JSON.stringify({ cosmos: cosmosMeta, blob: blobMeta, node: process.version }));

  const { database } = await cosmos.databases.createIfNotExists({ id: DB_ID });
  const { container: etl } = await database.containers.createIfNotExists({ id: "etl", partitionKey: { paths: ["/pk"] } });
  const { container: ingest } = await database.containers.createIfNotExists({ id: "ingest", partitionKey: { paths: ["/pk"] } });
  const archive = service.getContainerClient(`c1-archive-${TAG}`);
  await archive.create({ abortSignal: AbortSignal.timeout(30_000) });
  log("db/containers ready");

  // warmup (not measured)
  for (let i = 0; i < WARM_UPSERTS; i++) {
    try { await ingest.items.upsert(makeDoc(1000 + i, DOC_BYTES)); } catch (e) { noteErr("warmup-upsert", e); }
  }
  for (let i = 0; i < WARM_PUTS; i++) {
    try { await archive.getBlockBlobClient(`warm-${i}`).upload(crypto.randomBytes(65536), 65536, to()); } catch (e) { noteErr("warmup-put", e); }
  }
  log("warmup done, errors so far:", errCount);

  const rows = {};
  rows.ingest = await phaseIngest(etl);
  const { transformed } = await phaseTransform(etl);
  rows.archive = await phaseArchive(archive, transformed);
  const { results: comp, cIngLat } = await phaseComposite(ingest, archive);
  const worm = await phaseWorm(service, TAG);

  log("interference", JSON.stringify({
    seq_ingest_ops_per_sec: comp["seq-ingest"].ops_per_sec,
    seq_archive_ops_per_sec: comp["seq-archive"].ops_per_sec,
    seq_total_ops_per_sec: +(comp["seq-ingest"].ops_per_sec + comp["seq-archive"].ops_per_sec).toFixed(2),
    composite_ops_per_sec: comp["composite"].ops_per_sec,
    composite_ingest_ops_per_sec: comp["composite"].ingest_ops_per_sec,
    composite_archive_ops_per_sec: comp["composite"].archive_ops_per_sec,
    delta_pct: +(((comp["composite"].ops_per_sec - (comp["seq-ingest"].ops_per_sec + comp["seq-archive"].ops_per_sec)) / (comp["seq-ingest"].ops_per_sec + comp["seq-archive"].ops_per_sec)) * 100).toFixed(2),
    cosmos_p50_seq_ms: comp["seq-ingest"].p50_ms, cosmos_p95_seq_ms: comp["seq-ingest"].p95_ms,
    cosmos_p50_conc_ms: +pct(cIngLat, 50).toFixed(3), cosmos_p95_conc_ms: +pct(cIngLat, 95).toFixed(3),
    errors: errCount,
  }));

  log("total errors:", errCount, errors.length ? JSON.stringify(errors.slice(0, 10)) : "(none)");
  try { await database.delete(); } catch (e) { log("teardown db delete failed:", e?.statusCode ?? e?.message); }

  if (errCount > 0) { log("FAILED with errors"); process.exit(1); }
  log("done");
  process.exit(0);
}

main().catch((e) => { console.error("FATAL", e); process.exit(2); });
