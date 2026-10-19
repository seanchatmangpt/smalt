// b2_blob_ts.mjs — lane B-2: blob throughput via the REAL TypeScript
// @azure/storage-blob SDK against the live smalt substrate (private-port boot
// via scripts/bench/lib.sh bench_boot). Auth shape mirrors
// verification/ts/blob.probe.mjs (StorageSharedKeyCredential, account
// "smaltacct" / "smaltacct-key", plain-HTTP egress).
//
// Measures:
//   (a) put-block-blob 8 KiB and 64 KiB — sustained ops/sec over a 30 s
//       window each (sequential), >=200 ops, p50/p95/p99 latency.
//   (b) download byte-equality throughput MB/s, >=20 MiB total, every
//       download verified byte-for-byte against the uploaded payload.
//   (c) list-blobs flat over 100 blobs — full-page list latency.
//
// Emits one summary line per measurement to stdout as
//   SUMMARY <op> <n> <ops_per_sec> <p50_ms> <p95_ms> <p99_ms> <errors>
// plus extra fields after a "|", consumed by the B-2 driver for bench_emit.
// A failed run prints FAILED <op> <reason> and is recorded as failed — never
// estimated.
import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";

const require = createRequire(new URL("../../verification/ts/package.json", import.meta.url));
const { BlobServiceClient, StorageSharedKeyCredential } = require("@azure/storage-blob");

const EGRESS = process.env.B2_EGRESS || "http://127.0.0.1:39021";
const ACCOUNT = "smaltacct";
const ACCOUNT_KEY = "smaltacct-key";
const WINDOW_MS = 30_000;
const TAG = Date.now();
const errors = [];
let errCount = 0;

const service = new BlobServiceClient(
  `${EGRESS}/${ACCOUNT}`,
  new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY),
);
const container = service.getContainerClient(`b2-${TAG}`);
const to = () => ({ abortSignal: AbortSignal.timeout(60_000) });

function percentile(v, p) {
  const s = [...v].sort((a, b) => a - b);
  return s[Math.round((p / 100) * (s.length - 1))];
}
function summary(op, n, lat, extra) {
  const ops = n / (WINDOW_MS / 1000);
  const p50 = percentile(lat, 50).toFixed(3);
  const p95 = percentile(lat, 95).toFixed(3);
  const p99 = percentile(lat, 99).toFixed(3);
  console.log(`SUMMARY ${op} ${n} ${ops.toFixed(2)} ${p50} ${p95} ${p99} ${errCount} | ${extra}`);
}
function fail(op, e) {
  errCount++;
  const msg = String((e && e.message) || e).slice(0, 300);
  if (errors.length < 20) errors.push(`${op}: ${msg}`);
}

async function sustainedPut(name, size) {
  const payload = crypto.randomBytes(size);
  const blob = container.getBlockBlobClient(`${name}-${TAG}`);
  const lat = [];
  const deadline = Date.now() + WINDOW_MS;
  let n = 0;
  while (Date.now() < deadline) {
    const t0 = process.hrtime.bigint();
    try {
      await blob.upload(payload, size, to());
    } catch (e) {
      fail(`${name} put`, e);
    }
    lat.push(Number(process.hrtime.bigint() - t0) / 1e6);
    n++;
  }
  if (n < 200) {
    console.log(`FAILED ${name}-put only ${n} ops in window (<200) errors=${errCount} ${errors.join(" ;; ")}`);
    process.exit(1);
  }
  const mbps = ((n * size) / (1024 * 1024) / (WINDOW_MS / 1000)).toFixed(2);
  summary(`${name}-put-block-blob`, n, lat, `payload_bytes=${size} throughput_mbps=${mbps}`);
}

async function downloadThroughput() {
  const size = 512 * 1024; // substrate Put Blob limit is 1 MiB — 512 KiB blob, 48 downloads = 24 MiB >= 20 MiB
  const payload = crypto.randomBytes(size);
  const blob = container.getBlockBlobClient(`dl-${TAG}`);
  await blob.upload(payload, size, to());
  const lat = [];
  let total = 0, n = 0;
  const tStart = Date.now();
  while (total < 20 * 1024 * 1024) {
    const t0 = process.hrtime.bigint();
    try {
      const dl = await blob.download(undefined, undefined, to());
      const chunks = [];
      for await (const c of dl.readableStreamBody) chunks.push(Buffer.from(c));
      const got = Buffer.concat(chunks);
      if (!got.equals(payload)) {
        fail("download", new Error("byte-equality FAILED"));
        console.log(`FAILED download byte-equality at op ${n}`);
        process.exit(1);
      }
      total += got.length;
      lat.push(Number(process.hrtime.bigint() - t0) / 1e6);
      n++;
    } catch (e) {
      fail("download", e);
    }
  }
  const wall = (Date.now() - tStart) / 1000;
  const mbps = total / (1024 * 1024) / wall;
  const ops = n / wall;
  console.log(`SUMMARY download-byte-equality ${n} ${ops.toFixed(2)} ${percentile(lat, 50).toFixed(3)} ${percentile(lat, 95).toFixed(3)} ${percentile(lat, 99).toFixed(3)} ${errCount} | bytes=${total} throughput_mbps=${mbps.toFixed(2)} equality=verified`);
}

async function listFullPage() {
  const N = 100;
  await Promise.all(
    Array.from({ length: N }, (_, i) =>
      container.getBlockBlobClient(`list-${TAG}-${String(i).padStart(3, "0")}`)
        .upload(Buffer.from("x"), 1, to())),
  );
  const lat = [];
  let names = -1, n = 0;
  const tStart = Date.now();
  const deadline = tStart + 10_000;
  while (n < 50 && Date.now() < deadline) {
    const t0 = process.hrtime.bigint();
    try {
      const seen = [];
      for await (const b of container.listBlobsFlat({ pageSize: 1000 })) seen.push(b.name);
      names = seen.length;
      if (seen.length < N) { // sanity: the 100 list-* blobs must be visible
        fail("list", new Error(`expected >=${N} list blobs, saw ${seen.length}`));
      }
    } catch (e) {
      fail("list", e);
    }
    lat.push(Number(process.hrtime.bigint() - t0) / 1e6);
    n++;
  }
  if (n === 0 || names < 100) {
    console.log(`FAILED list-flat n=${n} names=${names} errors=${errCount} ${errors.join(" ;; ")}`);
    process.exit(1);
  }
  const wall = (Date.now() - tStart) / 1000;
  const ops = n / wall;
  console.log(`SUMMARY list-blobs-flat-fullpage ${n} ${ops.toFixed(2)} ${percentile(lat, 50).toFixed(3)} ${percentile(lat, 95).toFixed(3)} ${percentile(lat, 99).toFixed(3)} ${errCount} | blobs=${N} listed=${names}`);
  fs.writeFileSync(process.env.B2_LIST_LAT || "/tmp/b2-list-lat.txt", lat.map((x) => x.toFixed(3)).join("\n") + "\n");
  fs.writeFileSync(process.env.B2_LIST_LAT || "/tmp/b2-list-lat.txt", lat.map((x) => x.toFixed(3)).join("\n") + "\n");
}

async function main() {
  // Mutable container (substrate extension header, same as blob.probe.mjs).
  const res = await fetch(container.url, {
    method: "PUT",
    headers: { "x-ms-version": "2021-12-02", "x-ms-immutable-policy": "false" },
    signal: AbortSignal.timeout(30_000),
  });
  if (res.status !== 201) {
    console.log(`FAILED container-create status=${res.status} body=${(await res.text()).slice(0, 200)}`);
    process.exit(2);
  }

  // Warmup (not measured).
  const warm8 = crypto.randomBytes(8 * 1024);
  const warm64 = crypto.randomBytes(64 * 1024);
  for (let i = 0; i < 20; i++) {
    await container.getBlockBlobClient(`warm8-${i}`).upload(warm8, warm8.length, to());
    await container.getBlockBlobClient(`warm64-${i}`).upload(warm64, warm64.length, to());
  }
  await container.getBlockBlobClient(`warmdl-${TAG}`).upload(Buffer.alloc(1024, 7), 1024, to());
  const dlw = await container.getBlockBlobClient(`warmdl-${TAG}`).download(undefined, undefined, to());
  for await (const _ of dlw.readableStreamBody) {} // eslint-disable-line no-unused-vars

  await sustainedPut("8k", 8 * 1024);
  errCount = 0; errors.length = 0; // per-window error accounting
  await sustainedPut("64k", 64 * 1024);
  errCount = 0; errors.length = 0;
  await downloadThroughput();
  errCount = 0; errors.length = 0;
  await listFullPage();
  console.log("DONE");
}

main().catch((e) => {
  console.log(`FAILED harness ${String(e && e.stack || e).slice(0, 600)}`);
  process.exit(3);
});
