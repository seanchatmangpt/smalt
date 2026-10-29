#!/usr/bin/env node
/**
 * DOM-contract court (PAT-A) — plain-node assertion harness (no framework).
 *
 * Compiles the engine libs with the workspace's own tsc and exercises the
 * pure logic behind the semantic selector contract:
 *   P3  AppendQueue serialization — 50 rapid tasks yield ordered, contiguous
 *       results; a rejecting task does not break the queue.
 *   P3/P5 hydration math — nextSeqFromSegments / countUnsynced vectors.
 *   P5  accumulator replay determinism — rebuilding the chain from stored
 *       frames reproduces the live-append root and leaf count exactly.
 *   P6  cap refusal — >16 MiB -> ALLOC_CAP_EXCEEDED before any worker call;
 *       exactly 16 MiB passes.
 *   P2  andonRule mapping — status 1 -> reason, status 2 -> GUARD_FAULT,
 *       status 0 -> null.
 *
 * Exit 0 only when every assertion holds; exit 1 otherwise.
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const TSC = path.join(WS_ROOT, "node_modules", "typescript", "bin", "tsc");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ath2-dom-court-"));
fs.symlinkSync(path.join(WS_ROOT, "node_modules"), path.join(tmp, "node_modules"), "dir");
const tsconfig = {
  compilerOptions: {
    outDir: path.join(tmp, "out"),
    rootDir: WS_ROOT,
    module: "commonjs",
    moduleResolution: "node10",
    ignoreDeprecations: "6.0",
    target: "es2022",
    lib: ["es2022", "dom"],
    esModuleInterop: true,
    skipLibCheck: true,
    types: ["node"],
    typeRoots: [path.join(WS_ROOT, "node_modules", "@types")],
  },
  include: [
    path.join(WS_ROOT, "lib", "engine", "codec.ts"),
    path.join(WS_ROOT, "lib", "engine", "guard.ts"),
    path.join(WS_ROOT, "lib", "engine", "merkle.ts"),
    path.join(WS_ROOT, "lib", "engine", "journal-sync.ts"),
  ],
};
const cfgPath = path.join(tmp, "tsconfig.json");
fs.writeFileSync(cfgPath, JSON.stringify(tsconfig, null, 2));

const tsc = spawnSync(process.execPath, [TSC, "-p", cfgPath], { encoding: "utf8" });
if (tsc.status !== 0) {
  console.error(`[FAIL] tsc compile of engine libs:\n${tsc.stdout}${tsc.stderr}`);
  process.exit(1);
}
const engine = path.join(tmp, "out", "lib", "engine");
const { AppendQueue, nextSeqFromSegments, countUnsynced } = await import(
  pathToFileURL(path.join(engine, "journal-sync.js")).href
);
const { ALLOC_CAP_BYTES, capRefusal, andonRule } = await import(
  pathToFileURL(path.join(engine, "guard.js")).href
);
const { Accumulator } = await import(pathToFileURL(path.join(engine, "merkle.js")).href);

let failures = 0;
function check(name, cond, detail = "") {
  if (cond) {
    console.log(`[PASS] ${name}${detail ? ` — ${detail}` : ""}`);
  } else {
    failures++;
    console.error(`[FAIL] ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

// --- P3: serialization queue — 50-burst contiguity --------------------------

{
  const q = new AppendQueue();
  const results = [];
  await Promise.all(
    Array.from({ length: 50 }, (_, i) =>
      q.run(async () => {
        // Interleave async yields the way IndexedDB round-trips would.
        await new Promise((r) => setTimeout(r, Math.random() * 5));
        results.push(i);
        return i;
      }),
    ),
  );
  const contiguous = results.every((v, i) => v === i);
  check(
    "P3 50-burst admits serialize to a single ordered trail",
    results.length === 50 && contiguous,
    `first=${results[0]} last=${results[results.length - 1]} ordered=${contiguous}`,
  );
}

{
  // A rejecting task must not poison the turnstile for later admits.
  const q = new AppendQueue();
  const boom = q.run(async () => {
    throw new Error("store blew up");
  });
  let recovered = false;
  const after = q.run(async () => {
    recovered = true;
    return 42;
  });
  const boomOk = await boom.then(() => true, () => false);
  const v = await after;
  check("P3 queue survives a rejecting task", boomOk === false && recovered && v === 42);
}

// --- P3/P5: pure hydration math ---------------------------------------------

check(
  "P5 next-seq of an empty journal is 1",
  nextSeqFromSegments([]) === 1,
);
check(
  "P5 next-seq of a stored horizon is max+1",
  nextSeqFromSegments([{ seqId: 3 }, { seqId: 7 }, { seqId: 5 }]) === 8,
);
check(
  "P5 unsynced count above the ack floor",
  countUnsynced([{ seqId: 1 }, { seqId: 2 }, { seqId: 3 }, { seqId: 4 }], 2) === 2,
);
check(
  "P5 unsynced count with a fresh cursor is all segments",
  countUnsynced([{ seqId: 1 }, { seqId: 2 }], 0) === 2,
);

// --- P5: accumulator replay determinism (rebuild-from-frames) ----------------

{
  const enc = new TextEncoder();
  const frames = Array.from({ length: 7 }, (_, i) => enc.encode(`frame-${i}-opaque`));
  const live = new Accumulator();
  for (const f of frames) await live.append(f);
  // Cold Ash Rehydration: rebuild from stored frame bytes only.
  const rebuilt = new Accumulator();
  for (const f of frames) await rebuilt.append(f);
  check(
    "P5 replayed chain reproduces the live root byte-exact",
    rebuilt.rootHex() === live.rootHex() && rebuilt.rootHex().length === 64,
    `root=${live.rootHex().slice(0, 16)}…`,
  );
  check("P5 replayed leaf count matches", rebuilt.leafCount() === live.leafCount(), `leaves=${live.leafCount()}`);
  const drifted = new Accumulator();
  await drifted.append(enc.encode("frame-0-tampered"));
  for (let i = 1; i < frames.length; i++) await drifted.append(frames[i]);
  check(
    "P5 a tampered stored frame diverges the rebuilt root (replay detects drift)",
    drifted.rootHex() !== live.rootHex(),
  );
}

// --- P6: Bounded Arena cap (client-side, pre-gl_alloc) -----------------------

check(
  "P6 cap constant is exactly 16 MiB",
  ALLOC_CAP_BYTES === 16 * 1024 * 1024,
  `ALLOC_CAP_BYTES=${ALLOC_CAP_BYTES}`,
);
const over = capRefusal(ALLOC_CAP_BYTES + 1);
check(
  "P6 payload over the cap -> structured ALLOC_CAP_EXCEEDED, no worker call",
  over !== null && over.status === 1 && over.reason === "ALLOC_CAP_EXCEEDED",
);
check("P6 payload exactly at the cap passes", capRefusal(ALLOC_CAP_BYTES) === null);
check("P6 ordinary payload passes", capRefusal(128) === null);

// --- P2: structured andon rule mapping ---------------------------------------

check(
  "P2 worker refusal reason maps to the andon rule",
  andonRule({ status: 1, reason: "non-conformant: minCount at urn:s", ms: 3 }) ===
    "non-conformant: minCount at urn:s",
);
check(
  "P2 guard fault maps to GUARD_FAULT",
  andonRule({ status: 2, detail: "wasm not initialized", ms: 0 }) === "GUARD_FAULT",
);
check("P2 admitted verdict raises nothing", andonRule({ status: 0, ms: 5 }) === null);

fs.rmSync(tmp, { recursive: true, force: true });
console.log(`\n# dom-contract court verdict: ${failures === 0 ? "PASS" : "FAIL"} (${failures} failure(s))`);
process.exit(failures === 0 ? 0 : 1);
