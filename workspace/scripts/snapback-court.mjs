#!/usr/bin/env node
/**
 * P10 Elastic Snapback court — plain-node assertion harness (no framework).
 *
 * Compiles workspace/lib/engine/snapback.ts with the workspace tsc, then
 * exercises the refusal rollback against an in-memory IDB fake (a real
 * collaborator implementation of the SnapbackStoreOps interface, not a mock):
 *   1. planSnapback pure plan: purge = un-acked seqIds ascending,
 *      newCursor = serverHeadSeq, ordered transitions
 *   2. refusal at head 2 over 6 segments (2 acked) purges exactly seqIds 3-6
 *      and resets the cursor to 2 — asserted on real fake store state
 *   3. purged count matches deleted rows
 *   4. empty un-acked set: purged 0, cursor still reset
 *   5. unsorted input still yields ascending purge order
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

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ath2-snapback-court-"));
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
  include: [path.join(WS_ROOT, "lib", "engine", "snapback.ts")],
};
const cfgPath = path.join(tmp, "tsconfig.json");
fs.writeFileSync(cfgPath, JSON.stringify(tsconfig, null, 2));

const tsc = spawnSync(process.execPath, [TSC, "-p", cfgPath], { encoding: "utf8" });
if (tsc.status !== 0) {
  console.error(`[FAIL] tsc compile of lib/engine/snapback.ts:\n${tsc.stdout}${tsc.stderr}`);
  process.exit(1);
}
const sb = await import(
  pathToFileURL(path.join(tmp, "out", "lib", "engine", "snapback.js")).href
);

let failures = 0;
function check(name, cond, detail = "") {
  if (cond) {
    console.log(`[ok] ${name}`);
  } else {
    failures += 1;
    console.error(`[FAIL] ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

// In-memory fake of the journal store (real collaborator, state asserted).
function fakeStore(seed) {
  const segments = new Map(); // seqId -> segment
  for (const s of seed) segments.set(s.seqId, s);
  let cursor = 0;
  return {
    segments,
    getCursor: () => cursor,
    ops: {
      async listUnacked() {
        return [...segments.values()]
          .filter((s) => s.seqId > cursor && !s.acked)
          .sort((a, b) => a.seqId - b.seqId);
      },
      async deleteSeqIds(ids) {
        let n = 0;
        for (const id of ids) if (segments.delete(id)) n += 1;
        return n;
      },
      async setCursor(seq) {
        cursor = seq;
      },
    },
  };
}

function seg(seqId, acked) {
  return { seqId, acked, clientId: "1", ts: 0, op: 1, payload: new ArrayBuffer(0), frame: new ArrayBuffer(0) };
}

// 1. pure plan
const plan = sb.planSnapback([seg(3, false), seg(5, false), seg(7, false)], 2);
check("plan purge is the un-acked set ascending", JSON.stringify(plan.purgeSeqIds) === "[3,5,7]", JSON.stringify(plan.purgeSeqIds));
check("plan cursor snaps to server head", plan.newCursor === 2);
check(
  "plan transitions ordered REFUSED -> READY_STANDALONE",
  plan.transitions[0] === "SYNC_REFUSED_BY_SERVER" && plan.transitions[1] === "READY_STANDALONE",
);

// 2/3. refusal at head 2 over 6 segments (1-2 acked)
const store1 = fakeStore([seg(1, true), seg(2, true), seg(3, false), seg(4, false), seg(5, false), seg(6, false)]);
const applied = await sb.snapbackWithStore(store1.ops, 2);
check("applied purge seqIds 3..6", JSON.stringify(applied.purgeSeqIds) === "[3,4,5,6]", JSON.stringify(applied.purgeSeqIds));
check("applied purged count 4", applied.purged === 4, String(applied.purged));
check("store state: exactly seqIds 1,2 survive", JSON.stringify([...store1.segments.keys()].sort((a, b) => a - b)) === "[1,2]");
check("store cursor snapped to 2", store1.getCursor() === 2, String(store1.getCursor()));

// 4. empty un-acked set
const store2 = fakeStore([seg(1, true)]);
const applied2 = await sb.snapbackWithStore(store2.ops, 1);
check("empty un-acked purges 0", applied2.purged === 0 && applied2.purgeSeqIds.length === 0);
check("cursor still reset on empty purge", store2.getCursor() === 1);

// 5. unsorted input
const plan2 = sb.planSnapback([seg(9, false), seg(4, false), seg(6, false)], 3);
check("unsorted input purges ascending", JSON.stringify(plan2.purgeSeqIds) === "[4,6,9]", JSON.stringify(plan2.purgeSeqIds));

if (failures > 0) {
  console.error(`snapback-court: ${failures} FAIL`);
  process.exit(1);
}
console.log("snapback-court: all assertions passed");
