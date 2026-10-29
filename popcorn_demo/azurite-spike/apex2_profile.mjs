// APEX-2 profiler — isolate harness vs substrate vs blob-pipeline walls, via the
// same @azure/storage-blob SDK the apex probe uses (avoids hand-rolled signing).
//   P1 transport floor: container getProperties (trivial handler) @ concurrency C
//   P2 stageBlock only, 1 block, @ concurrency C (blob write path)
//   P3 full 5-op pipeline (3 stage + commit + get) @ concurrency C
//   P4 P3 with explicit keep-alive Agent (SDK uses undici in node >=18)
// Usage: node apex2_profile.mjs [backend=smalt|azurite] [C=500] [N=2000]
"use strict";
import crypto from "node:crypto";
import { BlobServiceClient, StorageSharedKeyCredential } from "@azure/storage-blob";

const backend = process.argv[2] || "smalt";
const C = parseInt(process.argv[3] || "500", 10);
const N = parseInt(process.argv[4] || "2000", 10);

const conf = backend === "smalt"
  ? { url: "http://127.0.0.1:8443/popcorn", account: "popcorn",
      key: process.env.SMALT_SB_SHARED_KEY ||
        crypto.createHash("sha256").update("popcorn" + "smalt-dev-sb").digest("base64") }
  : { url: "http://127.0.0.1:10100/devstoreaccount1", account: "devstoreaccount1",
      key: "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==" };

const svc = new BlobServiceClient(conf.url, new StorageSharedKeyCredential(conf.account, conf.key));
const tag = crypto.randomBytes(4).toString("hex");
const container = svc.getContainerClient(`apex2p-${tag}`);
const cr = await container.create();
if (cr._response.status !== 201) throw new Error("create " + cr._response.status);

function pct(arr, p) { const s = [...arr].sort((a, b) => a - b); return s[Math.floor((p / 100) * (s.length - 1))]; }
async function pool(n, c, fn) {
  const lats = []; let fails = 0; let next = 0;
  async function worker() {
    while (next < n) {
      const i = next++;
      try { lats.push(await fn(i)); } catch (e) { fails++; if (fails <= 3) console.log("  fail:", (e.message || e).slice(0, 140)); }
    }
  }
  const t0 = process.hrtime.bigint();
  await Promise.all(Array.from({ length: c }, worker));
  return { wall: Number(process.hrtime.bigint() - t0) / 1e6, lats, fails };
}

// P1: trivial handler
const p1r = await pool(N, C, async () => {
  const t0 = process.hrtime.bigint();
  const r = await container.getProperties();
  if (r._response.status !== 200) throw new Error("P1 " + r._response.status);
  return Number(process.hrtime.bigint() - t0) / 1e6;
});
console.log(`P1 getProps   C=${C} n=${N} wall=${p1r.wall.toFixed(1)}ms ops/s=${(N / (p1r.wall / 1000)).toFixed(0)} p50=${pct(p1r.lats, 50).toFixed(2)}ms p99=${pct(p1r.lats, 99).toFixed(2)}ms fails=${p1r.fails}`);

// P2: stageBlock only
const p2r = await pool(N, C, async (i) => {
  const blob = container.getBlockBlobClient(`pb-${i}`);
  const body = crypto.randomBytes(1024);
  const t0 = process.hrtime.bigint();
  const r = await blob.stageBlock(b64u(`pb-${i}`), body, body.length);
  if (r._response.status !== 201) throw new Error("P2 " + r._response.status);
  return Number(process.hrtime.bigint() - t0) / 1e6;
});
function b64u(b) { return Buffer.from(b).toString("base64url"); }
console.log(`P2 stageBlock C=${C} n=${N} wall=${p2r.wall.toFixed(1)}ms ops/s=${(N / (p2r.wall / 1000)).toFixed(0)} p50=${pct(p2r.lats, 50).toFixed(2)}ms p99=${pct(p2r.lats, 99).toFixed(2)}ms fails=${p2r.fails}`);

// P3: full 5-op pipeline
const p3n = Math.floor(N / 5);
const blk = crypto.randomBytes(1024);
const p3r = await pool(p3n, C, async (i) => {
  const blob = container.getBlockBlobClient(`fb-${i}`);
  const t0 = process.hrtime.bigint();
  const ids = [0, 1, 2].map((k) => b64u(`f-${i}-${k}`));
  for (let k = 0; k < 3; k++) {
    const r = await blob.stageBlock(ids[k], blk, blk.length);
    if (r._response.status !== 201) throw new Error("P3 stage " + r._response.status);
  }
  const rc = await blob.commitBlockList(ids);
  if (rc._response.status !== 201) throw new Error("P3 commit " + rc._response.status);
  const buf = await blob.downloadToBuffer();
  if (buf.length !== 3 * blk.length) throw new Error("P3 byte-len");
  return Number(process.hrtime.bigint() - t0) / 1e6;
});
console.log(`P3 full5ops   C=${C} n=${p3n} wall=${p3r.wall.toFixed(1)}ms ops/s=${(p3n / (p3r.wall / 1000)).toFixed(0)} p50=${pct(p3r.lats, 50).toFixed(2)}ms p99=${pct(p3r.lats, 99).toFixed(2)}ms fails=${p3r.fails}`);

process.exit(0);
