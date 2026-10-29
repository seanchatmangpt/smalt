#!/usr/bin/env node
/**
 * BK-118 asyncfn court — node assertion harness for the react-use
 * `useAsyncFn` pattern-port (workspace/lib/engine/useAsyncFn.ts).
 *
 * Asserts the ref-semantics the RU-3 audit named as the defect class:
 *   A1  in-flight standing is visible synchronously to a second rapid call
 *       (stale-closure `busy` boolean would read false);
 *   A2  rapid double-run drops nothing — both tasks execute, serialized by
 *       the journal turnstile (AppendQueue), transitions contiguous;
 *   A3  a throwing task surfaces `error` as state (loading false, error set,
 *       run resolves undefined — no rethrow) and does not poison the core;
 *   A4  a fresh run clears the previous error.
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

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bk118-asyncfn-court-"));
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
  include: [
    path.join(WS_ROOT, "lib", "engine", "useAsyncFn.ts"),
    path.join(WS_ROOT, "lib", "engine", "journal-sync.ts"),
  ],
};
const cfgPath = path.join(tmp, "tsconfig.json");
fs.writeFileSync(cfgPath, JSON.stringify(tsconfig, null, 2));

const tsc = spawnSync(process.execPath, [TSC, "-p", cfgPath], { encoding: "utf8" });
if (tsc.status !== 0) {
  console.error(`[FAIL] tsc compile of useAsyncFn + journal-sync:\n${tsc.stdout}${tsc.stderr}`);
  process.exit(1);
}
const engine = path.join(tmp, "out", "lib", "engine");
const { createAsyncFnCore } = await import(pathToFileURL(path.join(engine, "useAsyncFn.js")).href);
const { AppendQueue } = await import(pathToFileURL(path.join(engine, "journal-sync.js")).href);

let failures = 0;
function check(name, cond, detail = "") {
  if (cond) {
    console.log(`[PASS] ${name}${detail ? ` — ${detail}` : ""}`);
  } else {
    failures++;
    console.error(`[FAIL] ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

// --- A1: in-flight standing reads fresh on a rapid second call ---------------

{
  const core = createAsyncFnCore();
  let release;
  const gate = new Promise((r) => (release = r));
  const p1 = core.run(() => gate.then(() => "first"));
  check("A1 first run flips loading synchronously", core.loading === true);
  const seenBySecondCall = core.loading; // what a rapid second caller reads NOW
  const p2 = core.run(() => Promise.resolve("second"));
  check(
    "A1 rapid second call sees in-flight=true (stale-busy class dead)",
    seenBySecondCall === true && core.loading === true,
  );
  release();
  const [r1, r2] = await Promise.all([p1, p2]);
  check("A1 both rapid runs resolve — zero dropped", r1 === "first" && r2 === "second");
  check("A1 loading returns to false after settle", core.loading === false);
}

// --- A2: rapid double-admit serializes through the journal turnstile ---------

{
  // Model of useSovereignTerminal.admitAndCommit: no busy-gate drop; every
  // call runs; the journal AppendQueue serializes the appends.
  const q = new AppendQueue();
  const appended = [];
  const core = createAsyncFnCore();
  let release;
  const gate = new Promise((r) => (release = r));
  const admit = (payload) =>
    core.run(() =>
      q.run(async () => {
        await gate; // both admits are in flight before either appends
        appended.push(payload);
        return payload;
      }),
    );
  const p1 = admit("a");
  const p2 = admit("b");
  check("A2 both double-admits report busy", core.loading === true);
  release();
  await Promise.all([p1, p2]);
  check(
    "A2 zero dropped transitions — contiguous append trail",
    JSON.stringify(appended) === JSON.stringify(["a", "b"]),
    `trail=${JSON.stringify(appended)}`,
  );
}

// --- A3: throwing task surfaces error as state, core not poisoned ------------

{
  const core = createAsyncFnCore();
  const v = await core.run(async () => {
    throw new Error("store blew up");
  });
  check("A3 run resolves undefined on throw (no rethrow)", v === undefined);
  check("A3 error captured as state", core.error instanceof Error && core.error.message === "store blew up");
  check("A3 loading false after throw", core.loading === false);
  const after = await core.run(async () => "ok");
  check("A3 core not poisoned — next run succeeds", after === "ok");
}

// --- A4: a fresh run clears the previous error -------------------------------

{
  const core = createAsyncFnCore();
  await core.run(async () => {
    throw new Error("e1");
  });
  await core.run(async () => "fine");
  check("A4 successful rerun clears error", core.error === undefined);
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(`\n# bk118 asyncfn court verdict: ${failures === 0 ? "PASS" : "FAIL"} (${failures} failure(s))`);
process.exit(failures === 0 ? 0 : 1);
