#!/usr/bin/env node
/**
 * W3C-E row 8 court — tab-lease.ts over a real (fake-backed) LockManager.
 *
 * navigator.locks is not implemented in node, so the court compiles
 * tab-lease.ts with tsc to a temp dir, installs a hand-written mutex as
 * globalThis.navigator.locks (a real degraded collaborator — a literal
 * FIFO mutex, not a call-counting mock), and asserts end state:
 *
 *   1. fallback: with no locks manager the body runs, mode === "fallback".
 *   2. exclusive lease: two overlapping withWalLease calls serialize; the
 *      second observes the first's write (no interleaving).
 *   3. body failure surfaces typed as BODY_FAILED, lock still released.
 *   4. timeout on a held lease refuses as LEASE_TIMEOUT (steal recovers).
 *
 * Verdict PASS/FAIL printed as `# PASS: n / # FAIL: n`; exit 0 iff zero FAIL.
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
let pass = 0;
let fail = 0;
function check(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`# PASS: ${name}`);
  } else {
    fail++;
    console.log(`# FAIL: ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

// --- compile tab-lease.ts (plus its private surface) with tsc ---------------
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tab-lease-court-"));
const tsc = spawnSync(
  process.execPath,
  [
    path.join(WS_ROOT, "node_modules", "typescript", "bin", "tsc"),
    path.join(WS_ROOT, "lib", "engine", "tab-lease.ts"),
    "--outDir",
    tmp,
    "--module",
    "es2020",
    "--target",
    "es2020",
    "--moduleResolution",
    "bundler",
    "--skipLibCheck",
    "--ignoreConfig",
  ],
  { encoding: "utf8" },
);
if (tsc.status !== 0) {
  console.error(`# FAIL: tsc compile of tab-lease.ts\n${tsc.stdout}\n${tsc.stderr}`);
  process.exit(1);
}

const { withWalLease } = await import(
  pathToFileURL(path.join(tmp, "tab-lease.js")).href
);

// --- fake LockManager: a real FIFO exclusive mutex --------------------------
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
      const aborted = () =>
        opts.signal ? opts.signal.aborted : false;
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
        if (onAbort && opts.signal) {
          opts.signal.removeEventListener("abort", onAbort);
        }
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
  const nav = { locks: { request } };
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: nav,
  });
  return { waiterCount: () => waiters.length, holding: () => held.has("held") };
}

// --- 1. fallback: no locks manager ------------------------------------------
{
  const saved = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {},
  });
  const r = await withWalLease(async () => 41 + 1);
  check("fallback runs body with mode=fallback", r.ok && r.value === 42 && r.mode === "fallback", JSON.stringify(r));
  const e = await withWalLease(async () => {
    throw new Error("boom");
  });
  check(
    "fallback body failure is typed BODY_FAILED",
    !e.ok && e.error.code === "BODY_FAILED",
    JSON.stringify(e),
  );
  Object.defineProperty(globalThis, "navigator", saved);
}

// --- 2. exclusive lease serializes overlapping bodies -----------------------
{
  installFakeLocks();
  const events = [];
  const a = withWalLease(async () => {
    events.push("a:start");
    await new Promise((r) => setTimeout(r, 30));
    events.push("a:end");
    return "A";
  });
  const b = withWalLease(async () => {
    events.push("b:start");
    return "B";
  });
  const [ra, rb] = await Promise.all([a, b]);
  check("both bodies succeed under web-locks", ra.ok && ra.mode === "web-locks" && ra.value === "A" && rb.ok && rb.value === "B", JSON.stringify([ra, rb]));
  check(
    "bodies serialize (no interleaving)",
    events.join(",") === "a:start,a:end,b:start",
    events.join(","),
  );
}

// --- 3. body failure releases the lock --------------------------------------
{
  installFakeLocks();
  const e = await withWalLease(async () => {
    throw new Error("wal bitrot");
  });
  check(
    "web-locks body failure typed BODY_FAILED",
    !e.ok && e.error.code === "BODY_FAILED" && /wal bitrot/.test(e.error.detail),
    JSON.stringify(e),
  );
  const ok = await withWalLease(async () => "acquired-after-failure");
  check(
    "lock reacquired after a failing holder",
    ok.ok && ok.mode === "web-locks" && ok.value === "acquired-after-failure",
    JSON.stringify(ok),
  );
}

// --- 4. timeout on a held lease refuses typed --------------------------------
{
  installFakeLocks();
  const hold = withWalLease(async () => {
    await new Promise((r) => setTimeout(r, 200));
  });
  await new Promise((r) => setTimeout(r, 10)); // let the holder take the lock
  const t0 = Date.now();
  const e = await withWalLease(() => Promise.resolve("never"), { timeoutMs: 40 });
  const dt = Date.now() - t0;
  check(
    "held lease + timeoutMs refuses LEASE_TIMEOUT",
    !e.ok && e.error.code === "LEASE_TIMEOUT" && e.error.timeoutMs === 40 && dt < 150,
    JSON.stringify(e),
  );
  await hold;
}

// --- verdict ------------------------------------------------------------------
console.log(`# PASS: ${pass}`);
console.log(`# FAIL: ${fail}`);
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(fail === 0 ? 0 : 1);
