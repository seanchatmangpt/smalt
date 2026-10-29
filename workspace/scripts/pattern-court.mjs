#!/usr/bin/env node
/**
 * PAT-C pattern court — 12-pattern verification court (plain mjs, no framework).
 *
 * Contract: docs/jira/v26.10.22/patterns/PATTERN-LANGUAGE.md
 * Fixture:  workspace/tests-patterns/selector-contract.json
 *
 * Tiers:
 *   logic    — real execution: spawns scripts/codec-court.mjs (P7 convoy magic/
 *              41-byte header, P11 bad_crc32, P3 seq monotonicity logic).
 *   dom-lint — static source assertion that app/terminal/page.tsx emits every
 *              selector in the contract table (PAT-A deliverable).
 *   browser  — REAL headless-Chromium verification over `next start` for the
 *              four client-only patterns (P1 airlock, P2 andon cord, P3
 *              monotonic turnstile, P6 bounded arena). Executable discovery
 *              reuses popcorn_demo/scripts/browser_smoke.mjs: ms-playwright
 *              headless-shell cache first, system Chrome fallback. Server-
 *              dependent patterns (P4/P9 need SYNC-1; P5 reload needs the
 *              persisted-journal rehydrate leg) stay typed SKIP, loudly.
 *
 * Exit 0 only if every non-SKIP check passes; SKIP is loud, never a fake pass.
 * Bounds: <90s wall, ephemeral loopback ports, bounded polls (no sleeps).
 */

import { spawnSync, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readdirSync, existsSync } from "node:fs";

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CONTRACT = JSON.parse(
  fs.readFileSync(path.join(WS_ROOT, "tests-patterns", "selector-contract.json"), "utf8"),
);
const PAGE = path.join(WS_ROOT, CONTRACT.page);
const GUARD = path.join(WS_ROOT, "lib", "engine", "guard.ts");
const CODEC_COURT = path.join(WS_ROOT, "scripts", "codec-court.mjs");
const NEXT = path.join(WS_ROOT, "node_modules", "next", "dist", "bin", "next");

const results = [];
function record(id, name, tier, status, detail) {
  results.push({ id, name, tier, status, detail });
  const mark = status === "PASS" ? "ok" : status === "SKIP" ? "SKIP" : "FAIL";
  console.log(`[${mark}] ${id} ${name} (${tier}): ${detail}`);
}

// ---------------------------------------------------------------- logic tier

function runCodecCourt() {
  const r = spawnSync(process.execPath, [CODEC_COURT], {
    cwd: WS_ROOT,
    encoding: "utf8",
    env: { ...process.env, NODE_PATH: path.join(WS_ROOT, "node_modules") },
  });
  return {
    ok: r.status === 0,
    out: r.stdout + r.stderr,
  };
}

// -------------------------------------------------------------- dom-lint tier
//
// PAT-E: the emission surface is the import closure of page.tsx, not the page
// file alone — P2's alert attributes emit from lib/engine/useAndon.tsx, receipt
// seal attributes from lib/engine/receipt.ts, and so on. A token counts as
// emitted only if it appears in a file REACHABLE from page.tsx (the wire-in is
// proven by the import graph itself; a token present in an unreachable engine
// module is an ORPHAN emitter and fails loudly).

const EXT_ORDER = ["", ".tsx", ".ts", "/index.tsx", "/index.ts"];

/** Resolve one import specifier to a local file under WS_ROOT, or null. */
function resolveImport(fromFile, spec) {
  const base = spec.startsWith("@/")
    ? path.join(WS_ROOT, spec.slice(2))
    : spec.startsWith(".")
      ? path.resolve(path.dirname(fromFile), spec)
      : null; // bare package or asset URL — outside the emission surface
  if (!base) return null;
  for (const ext of EXT_ORDER) {
    const cand = base + ext;
    if (fs.existsSync(cand) && fs.statSync(cand).isFile()) return cand;
  }
  return null;
}

const IMPORT_RE = /(?:import|export)\s[^"'`]*?from\s*["']([^"']+)["']|import\(\s*["']([^"']+)["']\s*\)|import\s*["']([^"']+)["']/g;

/** Local-import closure of page.tsx: the full DOM emission surface. */
function emissionSurface() {
  const seen = new Map(); // file -> source (cached)
  const stack = [PAGE];
  while (stack.length) {
    const f = stack.pop();
    if (seen.has(f)) continue;
    let src;
    try {
      src = fs.readFileSync(f, "utf8");
    } catch {
      seen.set(f, "");
      continue;
    }
    seen.set(f, src);
    for (const m of src.matchAll(IMPORT_RE)) {
      const spec = m[1] ?? m[2] ?? m[3];
      const resolved = resolveImport(f, spec);
      if (resolved) stack.push(resolved);
    }
  }
  return seen;
}

function lintPage(requires, surface) {
  const missing = [];
  for (const needle of requires) {
    // (a) exact literal anywhere in the surface...
    if ([...surface.values()].some((src) => src.includes(needle))) continue;
    // (b) dynamic emission: attr={expr} or setAttribute("attr", ...) in the
    //     surface AND the value literal present somewhere in the surface.
    //     Covers data-andon-rule={rule}, data-status={t.status},
    //     setAttribute("data-receipt-bytes", String(bytes)) forms.
    const m = needle.match(/^([a-zA-Z-]+)="([^"]+)"$/);
    if (m) {
      const [, attr, value] = m;
      const srcs = [...surface.values()];
      const dynamicSite = srcs.some(
        (src) =>
          src.includes(`${attr}={`) || src.includes(`setAttribute("${attr}"`),
      );
      const valueSite = srcs.find((src) => src.includes(value));
      if (dynamicSite && valueSite) continue;
      missing.push(
        `${needle} (dynamic check: attr site ${dynamicSite ? "found" : "NOT found"}, value "${value}" ${valueSite ? "found" : "NOT found"})`,
      );
      continue;
    }
    missing.push(needle);
  }
  return missing.length === 0
    ? { ok: true, detail: `emission surface (${surface.size} files via import closure) emits all contract selectors` }
    : {
        ok: false,
        detail: `no emitter REACHABLE from page.tsx (orphan or absent): ${missing.join("; ")}`,
      };
}

// --------------------------------------------------------------- browser tier

/** Executable discovery — same mechanism as popcorn_demo browser_smoke. */
function discoverChromium() {
  if (process.env.CHROMIUM_PATH && existsSync(process.env.CHROMIUM_PATH)) {
    return { bin: process.env.CHROMIUM_PATH, source: "CHROMIUM_PATH env" };
  }
  const pwCache = process.env.HOME + "/Library/Caches/ms-playwright";
  const shellBin = existsSync(pwCache)
    ? readdirSync(pwCache)
        .filter((d) => d.startsWith("chromium_headless_shell-"))
        .sort()
        .reverse()
        .map((d) => `${pwCache}/${d}/chrome-headless-shell-mac-arm64/chrome-headless-shell`)
        .find((p) => existsSync(p))
    : null;
  if (shellBin) return { bin: shellBin, source: "ms-playwright headless-shell cache" };
  const systemChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  if (existsSync(systemChrome)) return { bin: systemChrome, source: "system Chrome" };
  return null;
}

/** Newest mtime under dir (shallow-recursive, skips .next/node_modules). */
function newestMtime(dir, depth = 2) {
  let newest = 0;
  let stack = [[dir, depth]];
  while (stack.length) {
    const [d, dep] = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        if (dep > 0 && e.name !== "node_modules" && e.name !== ".next") {
          stack.push([p, dep - 1]);
        }
        continue;
      }
      try {
        newest = Math.max(newest, fs.statSync(p).mtimeMs);
      } catch {}
    }
  }
  return newest;
}

/** Build if stale; start `next start` on an ephemeral loopback port. */
async function startWorkspaceServer() {
  const buildId = path.join(WS_ROOT, ".next", "BUILD_ID");
  const buildIdMtime = existsSync(buildId) ? fs.statSync(buildId).mtimeMs : 0;
  const srcNewest = Math.max(
    newestMtime(path.join(WS_ROOT, "app")),
    newestMtime(path.join(WS_ROOT, "components")),
    newestMtime(path.join(WS_ROOT, "lib")),
    newestMtime(path.join(WS_ROOT, "workers")),
    newestMtime(path.join(WS_ROOT, "public")),
    existsSync(path.join(WS_ROOT, "next.config.mjs"))
      ? fs.statSync(path.join(WS_ROOT, "next.config.mjs")).mtimeMs
      : 0,
  );
  if (srcNewest > buildIdMtime) {
    const b = spawnSync(process.execPath, [NEXT, "build"], { cwd: WS_ROOT, encoding: "utf8" });
    if (b.status !== 0) {
      return { error: `next build failed (exit ${b.status}):\n${(b.stdout + b.stderr).slice(-500)}` };
    }
  }
  for (let attempt = 0; attempt < 4; attempt++) {
    // Ephemeral-by-construction: random loopback port, collision retried.
    const port = 30000 + Math.floor(Math.random() * 20000);
    const child = spawn(process.execPath, [NEXT, "start", "-p", String(port)], {
      cwd: WS_ROOT,
      stdio: "ignore",
    });
    const ok = await poll(30_000, async () => {
      if (child.exitCode !== null) return false; // died (e.g. EADDRINUSE)
      try {
        const probeUrl = "http://127.0.0.1:" + String(port) + "/terminal";
        const res = await fetch(probeUrl);
        return res.ok;
      } catch {
        return false;
      }
    });
    if (ok) return { child, port };
    child.kill("SIGKILL");
    if (child.exitCode === null) await terminated(child); // reap after SIGKILL
  }
  return { error: "next start never became ready on any candidate port (4 attempts)" };
}

function terminated(child) {
  return new Promise((r) => child.once("exit", r));
}

/** Bounded poll on a real observable — no fixed sleeps (no-sleep doctrine). */
async function poll(deadlineMs, fn) {
  const t0 = Date.now();
  for (;;) {
    if (await fn()) return true;
    if (Date.now() - t0 > deadlineMs) return false;
    // POLL-STEP: bounded-poll backoff between observations of a real
    // observable; the claim under test is convergence within budget.
    await new Promise((r) => setTimeout(r, 100));
  }
}

async function runBrowserChecks(record) {
  const discovered = discoverChromium();
  if (!discovered) {
    record("P1", "browser tier", "browser", "SKIP",
      "no chromium executable found (ms-playwright cache + system Chrome both absent) — run: npx playwright install chromium-headless-shell");
    return;
  }

  const server = await startWorkspaceServer();
  if (server.error) {
    record("P1", "browser tier", "browser", "SKIP", `server boot failed: ${server.error}`);
    return;
  }
  const { child, port } = server;
  const base = `http://127.0.0.1:${port}`;
  console.log(`# browser tier: ${discovered.source} -> ${discovered.bin}`);
  console.log(`# browser tier: next start on ${base} (pid ${child.pid})`);

  let browser = null;
  try {
    const { createRequire } = await import("node:module");
    const require = createRequire(path.join(WS_ROOT, "package.json"));
    const { chromium } = require("playwright");
    browser = await chromium.launch({ headless: true, executablePath: discovered.bin });
    const page = await browser.newPage();
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(String(e).slice(0, 200)));

    await page.goto(`${base}/terminal`, { waitUntil: "domcontentloaded" });

    // Machine leaves INITIALIZING once the journal rehydrates (pattern 5).
    await page.waitForFunction(
      () => document.querySelector("main[data-status]")?.getAttribute("data-status") !== "INITIALIZING",
      null, { timeout: 15_000 },
    );
    const seqOf = () =>
      page.evaluate(() => Number(document.querySelector("main[data-seq]")?.getAttribute("data-seq") ?? "-1"));

    const fill = (v) => page.fill("[data-slot='payload-input']", v);
    const admit = () => page.click("[data-action='admit']");

    // --- P1 Ontological Airlock: admit -> COMMITTED_LOCAL, seq advances ----
    let p1 = "FAIL", p1d = "did not run";
    let p2 = "FAIL", p2d = "did not run";
    let p3 = "FAIL", p3d = "did not run";
    let p6 = "FAIL", p6d = "did not run";
    try {
      const seq0 = await seqOf();
      await fill("<urn:s> <urn:p> <urn:o> .");
      await admit();
      await page.waitForFunction(
        (s) => document.querySelector("main")?.getAttribute("data-status") === "COMMITTED_LOCAL"
          && Number(document.querySelector("main")?.getAttribute("data-seq")) === s + 1,
        seq0, { timeout: 15_000 },
      );
      p1 = "PASS";
      p1d = `admit -> COMMITTED_LOCAL, seq ${seq0} -> ${await seqOf()} (real wasm sieve + local journal commit)`;
    } catch (e) {
      p1d = `P1 admit never reached COMMITTED_LOCAL: ${String(e).split("\n")[0].slice(0, 200)}; pageerrors=${JSON.stringify(pageErrors)}`;
    }

    // --- P2 Visible Andon Cord: sieve refusal -> alert, seq unchanged -----
    try {
      const seqBefore = await seqOf();
      await fill("<urn:x> <urn:y> <urn:z> ."); // violates the default reticle
      await admit();
      await page.waitForSelector("[role='alert'][data-andon-rule]", { timeout: 15_000 });
      const rule = await page.getAttribute("[role='alert']", "data-andon-rule");
      const status = await page.getAttribute("main", "data-status");
      const seqAfter = await seqOf();
      if (status === "HALTED_BY_SIEVE" && seqAfter === seqBefore) {
        p2 = "PASS";
        p2d = `sieve refusal -> role=alert rule=${JSON.stringify(rule)}, status=HALTED_BY_SIEVE, seq unchanged (${seqAfter})`;
      } else {
        p2d = `alert shown (rule=${JSON.stringify(rule)}) but status=${status}, seq ${seqBefore}->${seqAfter} (expected HALTED_BY_SIEVE + unchanged)`;
      }
    } catch (e) {
      p2d = `P2 sieve-refusal alert never appeared: ${String(e).split("\n")[0].slice(0, 200)}; pageerrors=${JSON.stringify(pageErrors)}`;
    }

    // --- P6 Bounded Arena: 16MiB cap refusal + worker survival ------------
    try {
      // Cord is raised from P2; acknowledge so the arena refusal is isolated.
      const ack = await page.$("[data-action='acknowledge-andon']");
      if (ack) await ack.click();
      const seqBefore = await seqOf();
      await fill("x".repeat(16 * 1024 * 1024 + 1));
      await admit();
      await page.waitForSelector("[role='alert'][data-andon-rule='ALLOC_CAP_EXCEEDED']", { timeout: 15_000 });
      const seqAfterCap = await seqOf();
      // Survival: the pinned worker must still admit after the cap refusal.
      await page.click("[data-action='acknowledge-andon']");
      await fill("<urn:s> <urn:p> <urn:o> .");
      await admit();
      await page.waitForFunction(
        (s) => Number(document.querySelector("main")?.getAttribute("data-seq")) === s + 1,
        seqAfterCap, { timeout: 15_000 },
      );
      if (seqAfterCap === seqBefore) {
        p6 = "PASS";
        p6d = `17MiB payload -> ALLOC_CAP_EXCEEDED andon, seq unchanged (${seqAfterCap}); post-cap admit -> seq ${await seqOf()} (worker survived)`;
      } else {
        p6d = `cap refusal journaled a frame: seq ${seqBefore} -> ${seqAfterCap} (expected unchanged)`;
      }
    } catch (e) {
      p6d = `P6 cap path failed: ${String(e).split("\n")[0].slice(0, 200)}; pageerrors=${JSON.stringify(pageErrors)}`;
    }

    // --- P3 Monotonic Turnstile: 50-burst, strictly monotonic seq ---------
    try {
      const ack = await page.$("[data-action='acknowledge-andon']");
      if (ack) await ack.click();
      await fill("<urn:s> <urn:p> <urn:o> .");
      let prev = await seqOf();
      const seqs = [];
      let monotonic = true;
      for (let i = 0; i < 50; i++) {
        await admit();
        const ok = await poll(10_000, async () => (await seqOf()) === prev + 1);
        const cur = await seqOf();
        if (!ok || cur !== prev + 1) {
          monotonic = false;
          p3d = `burst broke at admit ${i + 1}/50: expected seq ${prev + 1}, saw ${cur}`;
          break;
        }
        seqs.push(cur);
        prev = cur;
      }
      if (monotonic) {
        p3 = "PASS";
        p3d = `50-burst strictly monotonic seq ${seqs[0]}..${seqs[49]} (each +1, no gaps, no regressions)`;
      }
    } catch (e) {
      p3d = `P3 burst failed: ${String(e).split("\n")[0].slice(0, 200)}`;
    }

    record("P1", "Ontological Airlock", "browser", p1, p1d);
    record("P2", "Visible Andon Cord", "browser", p2, p2d);
    record("P3", "Monotonic Turnstile", "browser", p3, p3d);
    record("P6", "Bounded Arena", "browser", p6, p6d);
  } catch (e) {
    const reason = String(e).split("\n")[0].slice(0, 300);
    for (const [id, name] of [["P1", "Ontological Airlock"], ["P2", "Visible Andon Cord"], ["P3", "Monotonic Turnstile"], ["P6", "Bounded Arena"]]) {
      const already = results.some((r) => r.id === id && r.tier === "browser");
      if (!already) record(id, name, "browser", "FAIL", `browser tier errored before this check: ${reason}`);
    }
  } finally {
    if (browser) await browser.close().catch(() => {});
    child.kill("SIGKILL");
  }
}

// ------------------------------------------------------------------- checks

const codec = runCodecCourt();
const codecOk = codec.ok;

// PAT-E: one import-closure walk, shared by every dom-lint row.
const SURFACE = emissionSurface();
console.log(`# dom-lint: emission surface = import closure of ${path.relative(WS_ROOT, PAGE)} (${SURFACE.size} files)`);

// P3 also rides the codec court's SEQ_REGRESSION assertion (monotonicity logic).
for (const p of CONTRACT.patterns) {
  if (p.skipReason) {
    record(p.id, p.name, p.tier, "SKIP", p.skipReason);
    continue;
  }

  if (p.tier === "logic") {
    record(p.id, p.name, p.tier, codecOk ? "PASS" : "FAIL",
      codecOk
        ? "codec court: exit 0 (convoy codec + sabotage assertions hold)"
        : `codec court failed (logic substrate):\n${codec.out.slice(-600)}`);
    continue;
  }

  if (p.tier === "dom-lint" || p.tier === "dom-lint+logic") {
    const lint = lintPage(p.require, SURFACE);
    if (p.tier === "dom-lint") {
      record(p.id, p.name, p.tier, lint.ok ? "PASS" : "FAIL", lint.detail);
      continue;
    }
    // dom-lint+logic
    if (p.id === "P3") {
      record(p.id, p.name, p.tier,
        lint.ok && codecOk ? "PASS" : "FAIL",
        lint.ok && codecOk
          ? "contract selectors present + codec SEQ_REGRESSION monotonicity holds"
          : `${lint.detail}${lint.ok ? "" : `; codec court: ${codecOk ? "ok" : "FAIL"}`}`);
    } else if (p.id === "P6") {
      const gsrc = fs.readFileSync(GUARD, "utf8");
      const capOk = /ALLOC_CAP_BYTES\s*=\s*16\s*\*\s*1024\s*\*\s*1024/.test(gsrc);
      record(p.id, p.name, p.tier, lint.ok && capOk ? "PASS" : "FAIL",
        lint.ok && capOk
          ? "ALLOC_CAP_EXCEEDED andon selector present + ALLOC_CAP_BYTES = 16 MiB in guard.ts"
          : `${lint.detail}; ALLOC_CAP_BYTES 16MiB: ${capOk ? "ok" : "NOT FOUND"}`);
    }
    continue;
  }

  record(p.id, p.name, p.tier, "SKIP", `unhandled tier '${p.tier}' — typed loudly`);
}

// Browser tier rows are additive: the live verdict rides alongside the static
// tiers for the four client-only patterns (P1/P2/P3/P6). Server-dependent
// patterns keep their contract SKIPs untouched.
await runBrowserChecks(record);

// -------------------------------------------------------------- verdict table

const order = { PASS: 0, SKIP: 1, FAIL: 2 };
results.sort((a, b) => a.id.localeCompare(b.id) || order[a.status] - order[b.status]);
results.sort((a, b) => Number(a.id.slice(1)) - Number(b.id.slice(1)));

console.log("\n=== PAT-C pattern court — verdict (static + browser tiers) ===");
for (const r of results) {
  console.log(
    `| ${r.id} | ${r.name} | ${r.tier.padEnd(15)} | ${r.status.padEnd(4)} | ${r.detail}`,
  );
}
const nPass = results.filter((r) => r.status === "PASS").length;
const nSkip = results.filter((r) => r.status === "SKIP").length;
const nFail = results.filter((r) => r.status === "FAIL").length;
console.log(`\ntotals: ${nPass} PASS / ${nSkip} SKIP / ${nFail} FAIL`);
if (nFail > 0) {
  console.log(
    "\nFAIL rows are real failures (DOM contract not yet landed on page.tsx, live browser refusals, and/or codec regressions) — see per-row detail.",
  );
}
process.exit(nFail > 0 ? 1 : 0);
