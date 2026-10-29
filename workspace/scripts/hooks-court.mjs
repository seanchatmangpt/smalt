#!/usr/bin/env node
/**
 * BK-130 hooks court — node assertion harness for the RU-3 adoption #2–5
 * pattern-ports (workspace/lib/engine/useNetworkState.ts, useIdle.ts,
 * useVisibility.ts, usePermission.ts).
 *
 * Compile gate: tsc (commonjs, dom lib) over the four hook files — the React
 * wrappers must typecheck against React 19 types. Then real runs of the
 * framework-free cores with fake events, fully deterministic (injected
 * timestamps and states, no clocks, no sleeps):
 *
 *   N1  offline flush gate: typed `OFFLINE` refusal, flush NEVER invoked
 *   N2  online flush gate: flush invoked, result propagated
 *   N3  reconnect transition predicate (offline→online only)
 *   I1  idle math: threshold boundary exact (30_000ms), custom timeout
 *   I2  auto-flush decision: idle AND unsynced>0, never one alone
 *   V1  resume predicate: hidden→visible only, prerender counts as hidden
 *   P1  permission classification incl. unsupported/unknown disclosure
 *   P2  pre-flight verdict: granted runs, all other standings typed-refuse
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

const FILES = [
  "useNetworkState.ts",
  "useIdle.ts",
  "useVisibility.ts",
  "usePermission.ts",
].map((f) => path.join(WS_ROOT, "lib", "engine", f));

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bk130-hooks-court-"));
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
    jsx: "react-jsx",
    types: ["node"],
    typeRoots: [path.join(WS_ROOT, "node_modules", "@types")],
  },
  include: FILES,
};
const cfgPath = path.join(tmp, "tsconfig.json");
fs.writeFileSync(cfgPath, JSON.stringify(tsconfig, null, 2));

const tsc = spawnSync(process.execPath, [TSC, "-p", cfgPath], { encoding: "utf8" });
if (tsc.status !== 0) {
  console.error(`[FAIL] tsc compile of hook ports:\n${tsc.stdout}${tsc.stderr}`);
  process.exit(1);
}
console.log("[ok] tsc compile: 4 hook ports typecheck (React wrappers included)");

const engine = path.join(tmp, "out", "lib", "engine");
const net = await import(pathToFileURL(path.join(engine, "useNetworkState.js")).href);
const idle = await import(pathToFileURL(path.join(engine, "useIdle.js")).href);
const vis = await import(pathToFileURL(path.join(engine, "useVisibility.js")).href);
const perm = await import(pathToFileURL(path.join(engine, "usePermission.js")).href);

let failures = 0;
function assert(id, cond, detail) {
  if (cond) console.log(`[ok] ${id}: ${detail}`);
  else {
    failures++;
    console.error(`[FAIL] ${id}: ${detail}`);
  }
}

// --- N1/N2/N3: network flush gating ----------------------------------------
{
  let flushCalls = 0;
  const flush = async () => {
    flushCalls++;
    return { ok: true, marker: "flushed" };
  };

  const off = net.gateFlushOnNetwork(false, flush);
  assert("N1", off.skipped === true && off.refusal?.code === "OFFLINE" && flushCalls === 0,
    `offline → typed OFFLINE skip, flush invoked ${flushCalls}x`);

  flushCalls = 0;
  const on = await net.gateFlushOnNetwork(true, flush);
  assert("N2", !on.skipped && flushCalls === 1 && on.promise && (await on.promise).marker === "flushed",
    `online → flush ran once, result propagated`);

  assert("N3", net.isReconnect(false, true) && !net.isReconnect(true, true)
    && !net.isReconnect(true, false) && !net.isReconnect(false, false),
    "reconnect predicate: offline→online only");
  assert("N3b", net.onlineClass(true) === "online" && net.onlineClass(false) === "offline",
    "onlineClass classification");
}

// --- I1/I2: idle math --------------------------------------------------------
{
  const core = idle.createIdleCore(); // default 30_000ms
  core.noteActivity(1_000);
  assert("I1", !core.isIdle(30_999) && core.isIdle(31_000) && core.idleFor(31_000) === 30_000,
    "idle boundary exact at timeoutMs, idleFor monotone");
  assert("I2a", !core.shouldAutoFlush(31_000, 0),
    "idle but zero unsynced → no auto-flush");
  assert("I2b", !core.shouldAutoFlush(2_000, 5),
    "unsynced but not idle → no auto-flush");
  assert("I2c", core.shouldAutoFlush(31_000, 5),
    "idle ≥30s AND unsynced>0 → auto-flush attempt");

  const core60 = idle.createIdleCore(60_000);
  core60.noteActivity(0);
  assert("I2d", !core60.shouldAutoFlush(59_999, 3) && core60.shouldAutoFlush(60_000, 3),
    "custom 60s timeout honored (RU-3 range)");
}
// --- V1: visibility resume ---------------------------------------------------
{
  assert("V1", vis.resumeAfterHidden("hidden", "visible")
    && !vis.resumeAfterHidden("visible", "visible")
    && !vis.resumeAfterHidden("visible", "hidden")
    && vis.resumeAfterHidden("prerender", "visible"),
    "resume predicate: hidden/prerender → visible only");
  assert("V1b", vis.flushOnResume === vis.resumeAfterHidden,
    "flushOnResume is the exposed wiring predicate");
}

// --- P1/P2: permission pre-flight --------------------------------------------
{
  assert("P1", perm.permissionClass("granted") === "granted"
    && perm.permissionClass("denied") === "denied"
    && perm.permissionClass("prompt") === "prompt"
    && perm.permissionClass(undefined) === "unknown"
    && perm.permissionClass("weird") === "unsupported",
    "permission classification incl. unsupported/unknown disclosure");
  const ok = perm.preflightPermission("publickey-credential-get", "granted");
  const denied = perm.preflightPermission("publickey-credential-get", "denied");
  const unsup = perm.preflightPermission("crypto", "unsupported");
  assert("P2", ok.ok === true
    && denied.ok === false && denied.refusal.code === "PERMISSION_REFUSED"
    && denied.refusal.state === "denied"
    && unsup.ok === false && unsup.refusal.state === "unsupported",
    "pre-flight: granted runs; denied/unsupported typed-refuse before challenge");
}

if (failures > 0) {
  console.error(`hooks-court: ${failures} FAIL`);
  process.exit(1);
}
console.log("hooks-court: all assertions green");
process.exit(0);
