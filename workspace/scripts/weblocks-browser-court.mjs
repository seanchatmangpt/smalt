// BK-WLB — browser-context court for useWebLocks (W3C-E row 8).
//
// BK-119B's node court exercised the real engine over a hand-written
// FIFO-mutex LockManager shim (node has no Web Locks). This court witnesses
// the browser-true face: real headless Chromium, real `navigator.locks`
// (native LockManager, NO shim), two pages of one SHARED BrowserContext
// (same origin -> same storage locker -> same lock manager), loading the REAL
// engine modules (useWebLocks.ts + tab-lease.ts) transpiled by the
// workspace's own tsc. Pattern: BK-SKIPPORT's browser_smoke.mjs.
//
// Legs:
//   B1 master-lease hold (page A): body runs under the lease; query() shows
//      the exclusive master lease HELD; snapshot is outcome-tracked (isMaster
//      stays false until the body completes — never ahead of the outcome).
//   B2 native surface: navigator.locks.request is the native function.
//   B3 second tab (page B, same context): while A holds, B's waiter registers
//      (inFlight=1), body never starts, snapshot read-only (isMaster=false,
//      lastMode="never-held"), query() from B sees A's held lock.
//   B4 release -> transfer: A completes (mode web-locks, isMaster=true,
//      lastMode disclosed), B's body starts only after A's release, B
//      completes as master.
//   B5 quiesced tail: after both bodies complete, query() shows no held
//      locks (the lease actually released).
//
// Exit contract: 0 all legs green; 1 any assertion failed; 3 typed SKIP
// (browser has no navigator.locks — honest UNKNOWN typing stands, the node
// shim court remains the witness; never a fake pass).
//
// Disclosed shim: the served react module specifier is rewritten to a
// pass-through shim so the browser can resolve `import "react"`. The court
// drives `WebLocksCore` directly (the hook is never exercised); the shim
// carries no assertion surface.

import { createServer } from "node:http";
import { readFile, writeFile, mkdir, rm } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const WORKSPACE = dirname(dirname(fileURLToPath(import.meta.url)));

let chromium;
try {
  ({ chromium } = require("playwright"));
  console.log("playwright: workspace node_modules");
} catch {
  ({ chromium } = require("/opt/homebrew/lib/node_modules/n8n/node_modules/playwright"));
  console.log("playwright: n8n global fallback");
}

// ---- transpile the real engine modules with the workspace's single tsc -----
const ts = require(join(WORKSPACE, "node_modules/typescript"));
const ENGINE = join(WORKSPACE, "lib", "engine");
const TMP = join(WORKSPACE, ".weblocks-browser-court");

const opts = {
  compilerOptions: {
    module: ts.ModuleKind.ES2020,
    target: ts.ScriptTarget.ES2020,
  },
};
await mkdir(TMP, { recursive: true });
const ENGINE_FILES = ["tab-lease.ts", "useWebLocks.ts"];
for (const f of ENGINE_FILES) {
  const src = await readFile(join(ENGINE, f), "utf8");
  const out = ts.transpileModule(src, opts).outputText;
  // Mechanical specifier rewrites: `react` is not served to the browser, and
  // tsc emits extensionless relative specifiers. Disclosed per the
  // no-silent-shim law; the shim is never an assertion surface.
  let rewritten = out.replace(/(["'])react\1/g, `"./react-shim.mjs"`);
  rewritten = rewritten.replace(/(from\s+["'])(\.\/tab-lease)(["'])/g, "$1$2.js$3");
  await writeFile(join(TMP, f.replace(/\.ts$/, ".js")), rewritten);
}

// ---- serve transpiled modules + shim ---------------------------------------
const HEADERS = {
  "content-type": "text/javascript",
  "cross-origin-opener-policy": "same-origin",
  "cross-origin-embedder-policy": "require-corp",
};
const server = createServer(async (req, res) => {
  const urlPath = req.url === "/" ? "/index.html" : new URL(req.url, "http://x").pathname;
  if (urlPath === "/react-shim.mjs") {
    res.writeHead(200, HEADERS);
    res.end(
      "export function useSyncExternalStore(sub, get, getServer) { return getServer ? getServer() : get(); }\n",
    );
    return;
  }
  if (urlPath === "/index.html") {
    res.writeHead(200, { ...HEADERS, "content-type": "text/html" });
    res.end("<!doctype html><html><body>wl-browser-court</body></html>");
    return;
  }
  try {
    const body = await readFile(join(TMP, urlPath));
    res.writeHead(200, HEADERS);
    res.end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
const BASE = "http://127.0.0.1:" + port;
console.log("serving " + TMP + " on " + BASE);

// ---- chromium discovery (same as browser_smoke.mjs) ------------------------
const { readdirSync, existsSync } = await import("node:fs");
const pwCache = process.env.HOME + "/Library/Caches/ms-playwright";
const shellBin = process.env.CHROMIUM_PATH ??
  (existsSync(pwCache)
    ? readdirSync(pwCache)
        .filter((d) => d.startsWith("chromium_headless_shell-"))
        .sort()
        .reverse()
        .map((d) => `${pwCache}/${d}/chrome-headless-shell-mac-arm64/chrome-headless-shell`)
        .find((p) => existsSync(p))
    : null);
const systemChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const resolvedBin = shellBin ?? (existsSync(systemChrome) ? systemChrome : null);
if (!resolvedBin) {
  console.error("[SKIP] browser unavailable: no chromium headless shell or system Chrome");
  process.exit(3);
}
const browser = await chromium.launch({ headless: true, executablePath: resolvedBin });

const passes = [];
const failures = [];
function check(cond, leg, msg) {
  if (cond) {
    passes.push(leg);
    console.log(`[ok] ${leg}: ${msg}`);
  } else {
    failures.push(leg);
    console.log(`[FAIL] ${leg}: ${msg}`);
  }
}

// Bounded observable poll (no-sleep doctrine): poll until pred, deadline-checked.
async function pollUntil(page, predBody, deadlineMs, label) {
  const start = Date.now();
  for (;;) {
    const v = await page.evaluate(new Function("return (" + predBody + ")();"));
    if (v) return v;
    if (Date.now() - start > deadlineMs) {
      throw new Error(`poll deadline exceeded: ${label} (${deadlineMs}ms)`);
    }
    await new Promise((r) => setTimeout(r, 50));
  }
}

// Load the real engine into a page and expose a harness surface.
async function setupPage(page) {
  await page.goto(`${BASE}/`);
  await page.evaluate(async () => {
    const mod = await import("/useWebLocks.js");
    const core = new mod.WebLocksCore();
    window.__wl = {
      core,
      bodyStarted: false,
      bodyDone: false,
      release: null,
      leaseP: null,
      native: null,
    };
    const req = globalThis.navigator && globalThis.navigator.locks && globalThis.navigator.locks.request;
    if (typeof req !== "function") {
      window.__wl.native = { present: false };
    } else {
      const s = Function.prototype.toString.call(req);
      window.__wl.native = {
        present: true,
        native: /\[native code\]/.test(s),
        repr: s.slice(0, 80),
      };
    }
  });
}

// Two pages of ONE shared BrowserContext: `browser.newPage()` mints an
// isolated context per page (separate lock managers — witnessed: both pages
// held "lawinput_wal_lock" exclusively with distinct clientIds). Web Locks
// bind per origin per storage locker, so master-lease semantics only exist
// within a shared context.
const context = await browser.newContext();
const pageA = await context.newPage();
const pageB = await context.newPage();
pageA.on("pageerror", (e) => console.log("[pageerror A]", String(e).slice(0, 300)));
pageB.on("pageerror", (e) => console.log("[pageerror B]", String(e).slice(0, 300)));
await setupPage(pageA);
await setupPage(pageB);

// Typed SKIP path: this browser may lack navigator.locks. Honest typing,
// never a fake pass — the node shim court remains the witness.
const nativeInfo = await pageA.evaluate(() => window.__wl.native);
console.log("browser: " + resolvedBin);
console.log("native check (page A): " + JSON.stringify(nativeInfo));
if (!nativeInfo.present) {
  console.log("[SKIP] navigator.locks absent in this browser — browser-true behavior stays UNKNOWN; node shim court remains the witness");
  await browser.close();
  server.close();
  await rm(TMP, { recursive: true, force: true });
  process.exit(3);
}

// ---- B1+B2: master lease held on page A ------------------------------------
await pageA.evaluate(() => {
  const c = window.__wl.core;
  window.__wl.leaseP = c.runUnderLease(async () => {
    window.__wl.bodyStarted = true;
    await new Promise((res) => { window.__wl.release = res; });
    window.__wl.bodyDone = true;
    return "master-body";
  });
});

await pollUntil(pageA, "() => window.__wl.bodyStarted", 10000, "A master body started");
const snapA1 = await pageA.evaluate(() => JSON.parse(JSON.stringify(window.__wl.core.getSnapshot())));
const qA = await pageA.evaluate(() => navigator.locks.query());
check(snapA1.supported === true, "B1a", "page A snapshot supported=true (real LockManager present)");
check(snapA1.inFlight === 1, "B1b", "page A inFlight=1 while body runs");
check(snapA1.isMaster === false, "B1c", "page A isMaster=false mid-body (standing is outcome-tracked: patched at completion, never ahead of the outcome)");
check(snapA1.lastMode === "never-held", "B1d", 'page A lastMode="never-held" until the body completes');
check(
  Array.isArray(qA.held) && qA.held.some((l) => l.name === "lawinput_wal_lock" && l.mode === "exclusive"),
  "B1e",
  "navigator.locks.query() shows the exclusive master lease held: " + JSON.stringify(qA.held),
);
check(snapA1.lockName === "lawinput_wal_lock", "B1f", "lock name is the pinned row-8 literal");
check(nativeInfo.native === true, "B2", "navigator.locks.request is native (no shim): " + nativeInfo.repr);

// ---- B3: second tab observes read-only standing ------------------------------
await pageB.evaluate(() => {
  const c = window.__wl.core;
  window.__wl.leaseB = c.runUnderLease(async () => {
    window.__wl.bodyStarted = true;
    await new Promise((res) => { window.__wl.releaseB = res; });
    window.__wl.bodyDone = true;
    return "secondary-body";
  });
});

// Poll B until its waiter registers (inFlight=1) — the body must NOT start.
await pollUntil(pageB, "() => window.__wl.core.getSnapshot().inFlight === 1", 10000, "B waiter registered");
const snapB1 = await pageB.evaluate(() => JSON.parse(JSON.stringify(window.__wl.core.getSnapshot())));
const bStartedWhileA = await pageB.evaluate(() => window.__wl.bodyStarted);
const qB = await pageB.evaluate(() => navigator.locks.query());
check(snapB1.supported === true, "B3a", "page B supported=true");
check(snapB1.isMaster === false, "B3b", "page B isMaster=false while A holds (read-only standing)");
check(snapB1.lastMode === "never-held", "B3c", 'page B lastMode="never-held" while waiting');
check(snapB1.inFlight === 1, "B3d", "page B inFlight=1 (waiting on the held lease)");
check(bStartedWhileA === false, "B3e", "page B body never started while A holds");
check(
  Array.isArray(qB.held) && qB.held.some((l) => l.name === "lawinput_wal_lock" && l.mode === "exclusive"),
  "B3f",
  "query() from page B sees A's held exclusive lock (shared lock manager, cross-tab): " + JSON.stringify(qB.held),
);

// ---- B4: release A -> B acquires ---------------------------------------------
const tRelease = Date.now();
await pageA.evaluate(() => window.__wl.release());
const resA = await pageA.evaluate(() => window.__wl.leaseP.then((r) => JSON.parse(JSON.stringify(r))));
check(resA.ok === true && resA.mode === "web-locks", "B4a", "A body completed, mode=" + resA.mode);
const snapA2 = await pageA.evaluate(() => JSON.parse(JSON.stringify(window.__wl.core.getSnapshot())));
check(snapA2.isMaster === true, "B4b", "page A isMaster=true after completing as master (outcome-tracked standing)");
check(snapA2.lastMode === "web-locks", "B4c", 'page A lastMode="web-locks" after completing (disclosed, not dropped)');

await pollUntil(pageB, "() => window.__wl.bodyStarted", 10000, "B body started after A released");
const tBStart = Date.now();
check(tBStart >= tRelease, "B4d", "B body started only after A released (release=" + tRelease + " <= bstart=" + tBStart + ")");
await pageB.evaluate(() => window.__wl.releaseB());
const resB = await pageB.evaluate(() => window.__wl.leaseB.then((r) => JSON.parse(JSON.stringify(r))));
check(resB.ok === true && resB.mode === "web-locks", "B4e", "B acquired after release, mode=" + resB.mode);
const snapB2 = await pageB.evaluate(() => JSON.parse(JSON.stringify(window.__wl.core.getSnapshot())));
check(snapB2.isMaster === true, "B4f", "page B isMaster=true after completing as master");
check(snapB2.lastMode === "web-locks", "B4g", 'page B lastMode="web-locks" after completing');
check(snapB2.inFlight === 0, "B4h", "page B inFlight drained to 0");

// ---- B5: quiesced tail --------------------------------------------------------
const qTail = await pageA.evaluate(() => navigator.locks.query());
check(
  Array.isArray(qTail.held) && qTail.held.length === 0,
  "B5a",
  "query() after both bodies complete: no held locks (lease actually released): " + JSON.stringify(qTail.held),
);

// ---- verdict ------------------------------------------------------------------
console.log("# PASS: " + passes.length);
console.log("# FAIL: " + failures.length);

await browser.close();
server.close();
await rm(TMP, { recursive: true, force: true });

const exitCode = failures.length === 0 ? 0 : 1;
console.log("weblocks-browser-court exit: " + exitCode);
process.exit(exitCode);
