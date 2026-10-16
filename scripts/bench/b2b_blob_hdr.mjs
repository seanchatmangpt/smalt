// b2b_blob_hdr.mjs — ERRC Raise lane 4: HDR-histogram re-emit of the B-2 blob
// 8 KiB put-block-blob lane, dual-instrumented. Same measurement as
// b2_blob_ts.mjs::sustainedPut("8k") (same boot pattern, same auth shape, same
// 30 s window, >=200 ops) but every latency is recorded BOTH into a
// hand-rolled sorted array (percentile() identical to b2_blob_ts.mjs) AND into
// an hdr-histogram-js histogram (recorded in microseconds, 3 sig digits).
// Emits rows to docs/jira/v26.10.14/bench/b2b-blob-hdr.jsonl with the same
// row schema as the b2 file plus hdr_total_count / hdr_mean_ms / hdr percentiles
// and explicit hand_rolled_* fields for the delta table.
//
// The hand-rolled lane (b2_blob_ts.mjs) is kept as the falsifier.
import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SDK_PKG = path.join(ROOT, "test/sdk-full/package.json");
const require = createRequire(SDK_PKG);
const { BlobServiceClient, StorageSharedKeyCredential } = require("@azure/storage-blob");
const hdr = require("hdr-histogram-js");

const EGRESS = process.env.B2_EGRESS || "http://127.0.0.1:39021";
const ACCOUNT = "smaltacct";
const ACCOUNT_KEY = "smaltacct-key";
const WINDOW_MS = 30_000;
const SIZE = 8 * 1024;
const TAG = Date.now();
const OUT = process.env.B2B_OUT || path.join(ROOT, "docs/jira/v26.10.14/bench/b2b-blob-hdr.jsonl");
const errors = [];
let errCount = 0;

const newHist = () => hdr.build({ lowestDiscernibleValue: 1, highestTrackableValue: 60_000_000, numberOfSignificantValueDigits: 3 });

const service = new BlobServiceClient(`${EGRESS}/${ACCOUNT}`, new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY));
const container = service.getContainerClient(`b2b-${TAG}`);
const to = () => ({ abortSignal: AbortSignal.timeout(60_000) });

// identical percentile semantics to b2_blob_ts.mjs (round index into sorted array)
function percentile(v, p) {
  const s = [...v].sort((a, b) => a - b);
  return s[Math.round((p / 100) * (s.length - 1))];
}

async function main() {
  const res = await fetch(container.url, {
    method: "PUT",
    headers: { "x-ms-version": "2021-12-02", "x-ms-immutable-policy": "false" },
    signal: AbortSignal.timeout(30_000),
  });
  if (res.status !== 201) {
    console.log(`FAILED container-create status=${res.status} body=${(await res.text()).slice(0, 200)}`);
    process.exit(2);
  }

  // warmup, not measured
  const warm = crypto.randomBytes(SIZE);
  for (let i = 0; i < 20; i++) await container.getBlockBlobClient(`warm-${i}`).upload(warm, warm.length, to());

  const payload = crypto.randomBytes(SIZE);
  const blob = container.getBlockBlobClient(`8k-${TAG}`);
  const lat = [];
  const hist = newHist();
  const deadline = Date.now() + WINDOW_MS;
  let n = 0;
  while (Date.now() < deadline) {
    const t0 = process.hrtime.bigint();
    try {
      await blob.upload(payload, SIZE, to());
    } catch (e) {
      errCount++;
      if (errors.length < 20) errors.push(String(e?.message ?? e).slice(0, 200));
    }
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    lat.push(ms);
    hist.recordValue(Math.max(1, Math.round(ms * 1000))); // microseconds
    n++;
  }
  if (n < 200) {
    console.log(`FAILED only ${n} ops (<200) errors=${errCount} ${errors.join(" ;; ")}`);
    process.exit(1);
  }
  const wallMs = WINDOW_MS;
  const mbps = ((n * SIZE) / (1024 * 1024) / (wallMs / 1000)).toFixed(2);

  const hp = (p) => +(hist.getValueAtPercentile(p) / 1000).toFixed(3);
  const row = {
    lane: "b2b", surface: "blob-ts-sdk-hdr", op: "8k-put-block-blob", n,
    ops_per_sec: +(n / (wallMs / 1000)).toFixed(2),
    p50_ms: +percentile(lat, 50).toFixed(3),
    p95_ms: +percentile(lat, 95).toFixed(3),
    p99_ms: +percentile(lat, 99).toFixed(3),
    errors: errCount,
    machine: process.env.B2B_MACHINE ? JSON.parse(process.env.B2B_MACHINE) : null,
    payload_bytes: SIZE,
    throughput_mbps: +mbps,
    hdr_total_count: hist.totalCount,
    hdr_mean_ms: +(hist.mean / 1000).toFixed(3),
    hdr_p50_ms: hp(50), hdr_p95_ms: hp(95), hdr_p99_ms: hp(99), hdr_p999_ms: hp(99.9), hdr_max_ms: +(hist.maxValue / 1000).toFixed(3),
    array_p50_ms: +percentile(lat, 50).toFixed(3),
    array_p95_ms: +percentile(lat, 95).toFixed(3),
    array_p99_ms: +percentile(lat, 99).toFixed(3),
    array_mean_ms: +(lat.reduce((a, b) => a + b, 0) / lat.length).toFixed(3),
    instrument: "dual array+hdr-histogram-js",
  };
  console.log(`SUMMARY 8k-put-block-blob ${n} ${row.ops_per_sec} ${row.p50_ms} ${row.p95_ms} ${row.p99_ms} ${errCount} | hdr_p95=${row.hdr_p95_ms} array_p95=${row.array_p95_ms} hdr_mean=${row.hdr_mean_ms}`);
  mkdirWrite(OUT, JSON.stringify(row) + "\n");
  console.log("DONE");
}

function mkdirWrite(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.appendFileSync(file, data);
}

main().catch((e) => {
  console.log(`FAILED harness ${String(e?.stack ?? e).slice(0, 600)}`);
  process.exit(3);
});
