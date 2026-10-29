// Popcorn in-browser smoke witness: serves public/out with COOP/COEP headers,
// boots the wasm BEAM in headless Chromium, waits for the Elixir smoke Task
// to report through Popcorn.JS into #status.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require("playwright"));
} catch {
  ({ chromium } = require("/opt/homebrew/lib/node_modules/n8n/node_modules/playwright"));
}

// BK-91: best-effort blob `<Cors>` seed before the walk. The blob plane
// answers OPTIONS preflight from STORED rules that are ETS-only (they do not
// survive a substrate bounce), so re-seed over the wire every run. Failure is
// NON-fatal here: the walk's own classifier then answers
// blob=SKIP(cors-preflight-403:...) loudly — a seeding failure must SKIP the
// blob leg, never fake a pass.
try {
  const { seedBlobCors } = await import(new URL("./seed_blob_cors.mjs", import.meta.url));
  await seedBlobCors();
} catch (e) {
  console.log(`[bk91-cors-seed] best-effort seed failed (blob leg will SKIP loudly if preflight is rule-gated): ${e.message}`);
}

const root = new URL("../public", import.meta.url).pathname;
const server = createServer(async (req, res) => {
  const urlPath = req.url === "/" ? "/index.html" : req.url;
  try {
    const body = await readFile(join(root, urlPath));
    res.writeHead(200, {
      "content-type": urlPath.endsWith(".html")
        ? "text/html"
        : urlPath.endsWith(".mjs") ? "text/javascript"
        : urlPath.endsWith(".json") ? "application/json"
        : urlPath.endsWith(".wasm") ? "application/wasm"
        : urlPath.endsWith(".br") ? "application/octet-stream"
        : "application/octet-stream",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
    res.end(body);
    return;
  } catch {
    res.writeHead(404).end("not found");
  }
});

await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
console.log(`serving ${root} on 127.0.0.1:${port}`);

const { readdirSync, existsSync } = await import("node:fs");
const pwCache = process.env.HOME + "/Library/Caches/ms-playwright";
const shellBin = (process.env.CHROMIUM_PATH) ??
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
  console.error("no chromium headless shell or system Chrome found; run: npx playwright install chromium-headless-shell");
  process.exit(1);
}
const browser = await chromium.launch({ headless: true, executablePath: resolvedBin });
const page = await browser.newPage();
page.on("console", (m) => console.log("[console]", m.text().slice(0, 300)));
page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 300)));

await page.goto(`http://127.0.0.1:${port}/index.html`);

const TIMEOUT = 90_000;
const start = Date.now();
let receipt = null;
while (Date.now() - start < TIMEOUT) {
  receipt = await page.evaluate(() => document.querySelector("#status")?.textContent ?? null);
  // The app writes twice: smoke legs first, then smoke + live legs composed.
  // Wait for the composed line ("live=") so the gate never reads a partial.
  if (receipt && receipt.includes("live=")) break;
  await new Promise((r) => setTimeout(r, 500));
}

console.log("SMOKE_RECEIPT:", receipt);
await browser.close();
server.close();

const allowOffline = process.env.SMOKE_ALLOW_OFFLINE === "1";
// Exit contract is keyed on the live= fragment (the loopback auth-path leg):
//   live=OK   -> 0   (other legs' =FAIL still forces 1 — fail-closed)
//   live=SKIP -> 3   (loud); SMOKE_ALLOW_OFFLINE=1 downgrades to 0, visibly
//   live=FAIL -> 1
// When live itself skipped, the substrate is the common cause and other legs'
// =FAIL fragments are substrate-down artifacts (witnessed: appconfig/rg emit
// =FAIL(fetch) on a downed substrate while 25 legs SKIP) — they ride loudly in
// the printed receipt; the gate keys on live.
const exitCode = (() => {
  if (!receipt) return 1;
  if (receipt.includes("live=FAIL")) return 1;
  if (receipt.includes("live=SKIP")) return allowOffline ? 0 : 3; // any live skip is loud
  if (receipt.includes("live=OK")) {
    return receipt.includes("=FAIL") ? 1 : 0;
  }
  return receipt.includes("=OK") ? 0 : 1;
})();

// ---- SCVD-T16: scvd fragment gate (fail-closed, typed) ----
// A present, well-formed scvd=OK fragment whose t16 wall is within 3x of the
// rolling best in tmp/bench/scvd-wasm-vs-host.jsonl rides as pass; anything
// else — fragment absent, scvd=SKIP/FAIL, malformed body, or t16 wall > 3x
// rolling best — is typed and forces exit 1. The existing live=SKIP exit-3
// path is computed above and this gate never upgrades a 3 to a pass.
import { readFileSync, existsSync as fileExists } from "node:fs";
const benchJsonl = new URL("../../tmp/bench/scvd-wasm-vs-host.jsonl", import.meta.url).pathname;
const T16_TOLERANCE = 3;
const scvdGate = (() => {
  if (!receipt || !receipt.includes("scvd=")) {
    return { verdict: 1, reason: "SCVD-FRAGMENT-MISSING:no scvd= fragment in SMOKE_RECEIPT" };
  }
  const m = receipt.match(/scvd=(OK|SKIP|FAIL)\(([^)]*)\)/);
  if (!m) {
    return { verdict: 1, reason: `SCVD-FRAGMENT-MALFORMED:${receipt.match(/scvd=[^;]*/)?.[0] ?? "?"}` };
  }
  const [, state, body] = m;
  if (state !== "OK") {
    return { verdict: 1, reason: `SCVD-DEGRADED:${state}:${body}` };
  }
  const t16 = Number((body.match(/t16:([0-9.]+)ms/) ?? [])[1]);
  if (!Number.isFinite(t16) || t16 <= 0) {
    return { verdict: 1, reason: `SCVD-FRAGMENT-MALFORMED:no-t16-wall:${body}` };
  }
  if (!fileExists(benchJsonl)) {
    return { verdict: 1, reason: "SCVD-BASELINE-MISSING:" + benchJsonl };
  }
  const t16Walls = readFileSync(benchJsonl, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter((r) => r && typeof r.wasm_fragment === "string" && r.wasm_fragment.includes("scvd=OK(t16:"))
    .map((r) => Number(r.wasm_fragment.match(/t16:([0-9.]+)ms/)?.[1]))
    .filter(Number.isFinite);
  if (!t16Walls.length) {
    return { verdict: 0, reason: `SCVD-OK:t16:${t16}ms (no ramp16 fragment rows in baseline; nothing to compare)` };
  }
  const rollingBest = Math.min(...t16Walls);
  if (t16 > T16_TOLERANCE * rollingBest) {
    return { verdict: 1, reason: `SCVD-DEGRADED:t16:${t16}ms > ${T16_TOLERANCE}x rolling-best ${rollingBest}ms` };
  }
  return { verdict: 0, reason: `SCVD-OK:t16:${t16}ms <= ${T16_TOLERANCE}x rolling-best ${rollingBest}ms` };
})();
console.log("SCVD_GATE:", scvdGate.reason);

const finalExit = exitCode === 3 ? 3 : Math.max(exitCode, scvdGate.verdict);
process.exit(finalExit);
// Healthy cache as of 2026-10-20: chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell (Chrome for Testing 156.0.8078.4); discovery picks it before the system-Chrome fallback.
