#!/usr/bin/env node
/**
 * W3C-E row 8 court — useWebLocks.ts + tab-lease.ts over a real
 * (fake-backed) LockManager.
 *
 * Node has no navigator.locks, so the court compiles the hook + tab-lease
 * with tsc (React wrappers included, honest typing) and installs a
 * hand-written FIFO exclusive mutex as globalThis.navigator.locks — a real
 * degraded collaborator, not a call-counting mock. Asserts end state:
 *
 *   L1 compile gate: useWebLocks.ts + tab-lease.ts typecheck (dom lib).
 *   L2 unsupported honestly typed: no navigator.locks → fallback body runs,
 *      snapshot.supported=false, isMaster=false, lastMode=fallback.
 *   L3 master-lease acquired/exclusive: overlapping runUnderLease bodies
 *      serialize (no interleaving), mode === "web-locks", isMaster=true.
 *   L4 secondary-observer read-only: while the master holds the lease, a
 *      secondary core's body has NOT started (waiting, inFlight>0, body
 *      marker absent); it observes isMaster=false the whole wait; it runs
 *      only after release and never interleaves.
 *   L5 server snapshot is the unsupported default (pattern 13).
 *   L6 snapshot standing moves with the real outcome: a failing body
 *      discloses lastMode but leaves isMaster=false on the failure.
 *
 * Exit 0 only when every leg holds; exit 1 otherwise.
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const TSC = path.join(WS_ROOT, "node_modules", "typescript", "bin", "tsc");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bk119b-weblocks-court-"));
fs.symlinkSync(path.join(WS_ROOT, "node_modules"), path.join(tmp, "node_modules"), "dir");
const cfgPath = path.join(tmp, "tsconfig.json");
fs.writeFileSync(
  cfgPath,
  JSON.stringify(
    {
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
        jsx: "react-jsx",
        types: ["node"],
        typeRoots: [path.join(WS_ROOT, "node_modules", "@types")],
      },
      include: [
        path.join(WS_ROOT, "lib", "engine", "useWebLocks.ts"),
        path.join(WS_ROOT, "lib", "engine", "tab-lease.ts"),
      ],
    },
    null,
    2,
  ),
);

const tsc = spawnSync(process.execPath, [TSC, "-p", cfgPath], { encoding: "utf8" });
if (tsc.status !== 0) {
  console.error(`[FAIL] tsc compile of useWebLocks + tab-lease:\n${tsc.stdout}${tsc.stderr}`);
  process.exit(1);
}
console.log("[ok] L1 tsc compile: useWebLocks.ts + tab-lease.ts typecheck (React + dom types)");

const engine = path.join(tmp, "out", "lib", "engine");
const wl = await import(pathToFileURL(path.join(engine, "useWebLocks.js")).href);

let pass = 0;
let fail = 0;
function check(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`[ok] ${name}`);
  } else {
    fail++;
    console.error(`[FAIL] ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

// --- fake LockManager: a real FIFO exclusive mutex (same shape as
// --- tab-lease-court's) ------------------------------------------------------
function installFakeLocks() {
  const held = new Set();
  const waiters = [];
  const release = () => {
    const next = waiters.shift();
    if (next) next();
    else held.delete("held");
  };
  const request = (name, optsOrCb, maybeCb) => {
    const opts = maybeCb ? optsOrCb : {};
    const granted = maybeCb ?? optsOrCb;
    return new Promise((resolve, reject) => {
      let onAbort = null;
      const aborted = () => (opts.signal ? opts.signal.aborted : false);
      if (opts.signal) {
        onAbort = () => {
          const i = waiters.indexOf(run);
          if (i >= 0) {
            waiters.splice(i, 1);
            reject(new Error("AbortError"));
          }
        };
        opts.signal.addEventListener("abort", onAbort, { once: true });
      }
      const run = () => {
        if (onAbort && opts.signal) opts.signal.removeEventListener("abort", onAbort);
        let done = false;
        const finish = (v) => {
          if (done) return;
          done = true;
          release();
          resolve(v);
        };
        granted({ name, mode: "exclusive" }).then(finish, (e) => {
          done = true;
          release();
          reject(e);
        });
      };
      if (aborted()) {
        reject(new Error("AbortError"));
        return;
      }
      if (!held.has("held")) {
        held.add("held");
        run();
      } else {
        waiters.push(run);
      }
    });
  };
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { locks: { request } },
  });
  return { waiterCount: () => waiters.length };
}

// --- L2: unsupported runtime honestly typed -----------------------------------
{
  const saved = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: {} });
  const core = new wl.WebLocksCore();
  const r = await core.runUnderLease(async () => "fallback-body-ran");
  const s = core.getSnapshot();
  check(
    "L2a body runs in fallback, mode typed",
    r.ok && r.value === "fallback-body-ran" && r.mode === "fallback",
    JSON.stringify(r),
  );
  check(
    "L2b snapshot discloses unsupported/degraded",
    s.supported === false && s.isMaster === false && s.lastMode === "fallback" && s.inFlight === 0,
    JSON.stringify(s),
  );
  Object.defineProperty(globalThis, "navigator", saved);
}

// --- L3: master-lease acquired + exclusive ------------------------------------
{
  installFakeLocks();
  const core = new wl.WebLocksCore();
  const events = [];
  const a = core.runUnderLease(async () => {
    events.push("a:start");
    await new Promise((r) => setTimeout(r, 30));
    events.push("a:end");
    return "A";
  });
  const b = core.runUnderLease(async () => {
    events.push("b:start");
    return "B";
  });
  const [ra, rb] = await Promise.all([a, b]);
  const s = core.getSnapshot();
  check(
    "L3a both bodies succeed under the real lease",
    ra.ok && ra.mode === "web-locks" && ra.value === "A" && rb.ok && rb.mode === "web-locks",
    JSON.stringify([ra, rb]),
  );
  check(
    "L3b bodies serialize (exclusive, no interleaving)",
    events.join(",") === "a:start,a:end,b:start",
    events.join(","),
  );
  check(
    "L3c snapshot: supported, master standing, drained inFlight",
    s.supported === true && s.isMaster === true && s.lastMode === "web-locks" && s.inFlight === 0,
    JSON.stringify(s),
  );
}

// --- L4: secondary-observer read-only while master holds ----------------------
{
  installFakeLocks();
  const master = new wl.WebLocksCore();
  const secondary = new wl.WebLocksCore();
  const events = [];
  const masterHold = master.runUnderLease(async () => {
    events.push("master:start");
    await new Promise((r) => setTimeout(r, 60));
    events.push("master:end");
    return "M";
  });
  await new Promise((r) => setTimeout(r, 10)); // master holds the lease now
  const secondaryDuring = secondary.getSnapshot();
  const secondaryBody = secondary.runUnderLease(async () => {
    events.push("secondary:start");
    return "S";
  });
  await new Promise((r) => setTimeout(r, 20));
  const secondaryWaiting = secondary.getSnapshot();
  const eventsAtWait = [...events];
  const rs = await secondaryBody;
  const rm = await masterHold;
  check(
    "L4a master body ran to completion first",
    rm.ok && rm.mode === "web-locks" && events.slice(0, 2).join(",") === "master:start,master:end",
    events.join(","),
  );
  check(
    "L4b secondary body never started while master held",
    !events.includes("secondary:start|mid") && events.indexOf("secondary:start") > events.indexOf("master:end"),
    events.join(","),
  );
  check(
    "L4c secondary observed non-master + in-flight while waiting",
    secondaryDuring.isMaster === false &&
      secondaryWaiting.isMaster === false &&
      secondaryWaiting.supported === true &&
      secondaryWaiting.inFlight === 1 &&
      !eventsAtWait.includes("secondary:start"),
    JSON.stringify({ during: secondaryDuring, waiting: secondaryWaiting }),
  );
  check(
    "L4d secondary ran only after release, never interleaved",
    rs.ok && rs.mode === "web-locks" && events.join(",") === "master:start,master:end,secondary:start",
    events.join(","),
  );
}

// --- L5/L6: server default + outcome-tracked standing --------------------------
{
  const s0 = wl.initialWebLocksSnapshot();
  check(
    "L5 server snapshot is the unsupported default (pattern 13)",
    s0.supported === false && s0.lastMode === "never-held" && s0.isMaster === false && s0.lockName === "lawinput_wal_lock",
    JSON.stringify(s0),
  );
  installFakeLocks();
  const core = new wl.WebLocksCore();
  await core.runUnderLease(async () => "ok");
  const e = await core.runUnderLease(async () => {
    throw new Error("bitrot");
  });
  const s = core.getSnapshot();
  check(
    "L6 body failure typed BODY_FAILED, isMaster falls back to false, lastMode disclosed",
    !e.ok && e.error.code === "BODY_FAILED" && s.isMaster === false && s.lastMode === "web-locks" && s.inFlight === 0,
    JSON.stringify({ e, s }),
  );
}

console.log(`# PASS: ${pass}`);
console.log(`# FAIL: ${fail}`);
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(fail === 0 ? 0 : 1);
