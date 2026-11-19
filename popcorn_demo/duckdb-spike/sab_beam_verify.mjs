// FNOX-SJ-WASM-3: DuckDB-Wasm SAB (COI) build next to a live Popcorn BEAM, under COOP/COEP.
// One isolated origin serves:  /popcorn/* -> popcorn_demo/public   /duck/* -> this dir's node_modules.
// Page boots Popcorn (BEAM worker), pings the BEAM, runs `SELECT 42 AS answer` on the duckdb COI
// bundle (SharedArrayBuffer + pthread worker), pings the BEAM again.
// Prereq: `npm install` in this dir (node_modules/@duckdb/duckdb-wasm ships the *-coi.* files).
// SAB_VERIFY_STOP_BEAM=1: mutation, Popcorn is deinit'ed before the pre-query ping; must exit nonzero
// and never print select_result=.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { readdirSync, existsSync } from "node:fs";
import { join, normalize } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require("playwright"));
} catch {
  ({ chromium } = require("/opt/homebrew/lib/node_modules/n8n/node_modules/playwright"));
}

const stopBeam = process.env.SAB_VERIFY_STOP_BEAM === "1";
const here = new URL(".", import.meta.url).pathname;
const popcornRoot = new URL("../public", import.meta.url).pathname;
const duckDist = join(here, "node_modules/@duckdb/duckdb-wasm/dist");
const need = ["duckdb-coi.wasm", "duckdb-browser-coi.worker.js", "duckdb-browser-coi.pthread.worker.js", "duckdb-browser.mjs"];
const missing = need.filter((f) => !existsSync(join(duckDist, f)));
if (missing.length || !existsSync(join(popcornRoot, "out/index.mjs"))) {
  console.error(`missing prerequisites: ${missing.join(",")} (run npm install in ${here}); popcorn out/index.mjs required`);
  process.exit(2);
}

const MIME = { ".html": "text/html", ".mjs": "text/javascript", ".js": "text/javascript", ".json": "application/json", ".wasm": "application/wasm" };
const PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>sab-beam</title>
<script type="importmap">{ "imports": { "apache-arrow": "/duck-arrow/Arrow.dom.mjs", "tslib": "/duck-tslib/tslib.es6.mjs", "flatbuffers": "/duck-fb/flatbuffers.js" } }</script>
</head><body><pre id="status">starting</pre></body></html>`;

const mounts = [
  ["/popcorn/", popcornRoot],
  ["/duck/", duckDist],
  ["/duck-arrow/", join(here, "node_modules/apache-arrow")],
  ["/duck-tslib/", join(here, "node_modules/tslib")],
  ["/duck-fb/", join(here, "node_modules/flatbuffers/mjs")],
];
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(req.url.split("?")[0]);
  const base = {
    "cross-origin-opener-policy": "same-origin",
    "cross-origin-embedder-policy": "require-corp",
    "cross-origin-resource-policy": "same-origin",
  };
  if (p === "/" || p === "/index.html") {
    res.writeHead(200, { ...base, "content-type": "text/html" }).end(PAGE);
    return;
  }
  const m = mounts.find(([prefix]) => p.startsWith(prefix));
  if (!m) return void res.writeHead(404, base).end("not found");
  const file = normalize(join(m[1], p.slice(m[0].length)));
  if (!file.startsWith(m[1])) return void res.writeHead(403, base).end("forbidden");
  try {
    const body = await readFile(file);
    res.writeHead(200, { ...base, "content-type": MIME[file.slice(file.lastIndexOf("."))] ?? "application/octet-stream" }).end(body);
  } catch {
    res.writeHead(404, base).end("not found");
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

const pwCache = process.env.HOME + "/Library/Caches/ms-playwright";
const shellBin = process.env.CHROMIUM_PATH ??
  (existsSync(pwCache)
    ? readdirSync(pwCache)
        .filter((d) => d.startsWith("chromium_headless_shell-"))
        .sort().reverse()
        .map((d) => `${pwCache}/${d}/chrome-headless-shell-mac-arm64/chrome-headless-shell`)
        .find((p) => existsSync(p))
    : null);
const systemChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const bin = shellBin ?? (existsSync(systemChrome) ? systemChrome : null);
if (!bin) {
  console.error("no chromium found; run: npx playwright install chromium-headless-shell");
  server.close();
  process.exit(2);
}

const browser = await chromium.launch({ headless: true, executablePath: bin });
const page = await browser.newPage();
page.on("console", (m) => console.log("[console]", m.text().slice(0, 300)));
page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 300)));
await page.goto(`http://127.0.0.1:${port}/index.html`);

let out;
let failure = null;
try {
  out = await page.evaluate(async ({ stopBeam }) => {
    const r = { crossOriginIsolated: self.crossOriginIsolated === true, sab: typeof SharedArrayBuffer === "function" };
    const { Popcorn, atom } = await import("/popcorn/out/index.mjs");
    const popcorn = await Popcorn.init();
    const ping = async () => {
      try {
        await popcorn.call("Elixir.PopcornDemo.Supervisor", atom("which_children"), { timeoutMs: 15000 });
        return true;
      } catch (e) {
        r.beam_error = String(e && e.message ? e.message : e).slice(0, 200);
        return false;
      }
    };
    r.beam_before_boot = await ping();
    if (stopBeam) popcorn.deinit();
    r.beam_pre = stopBeam ? await ping() : r.beam_before_boot;
    if (!r.crossOriginIsolated || !r.sab || !r.beam_pre) return r;

    const duck = await import("/duck/duckdb-browser.mjs");
    const coi = {
      mainModule: "/duck/duckdb-coi.wasm",
      mainWorker: "/duck/duckdb-browser-coi.worker.js",
      pthreadWorker: "/duck/duckdb-browser-coi.pthread.worker.js",
    };
    const bundle = await duck.selectBundle({ coi });
    r.build = bundle.mainWorker.includes("-coi.") ? "duckdb-browser-coi" : "duckdb-browser-other";
    if (r.build !== "duckdb-browser-coi") return r;
    const worker = new Worker(bundle.mainWorker);
    const db = new duck.AsyncDuckDB(new duck.ConsoleLogger(), worker);
    await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
    const conn = await db.connect();
    const table = await conn.query("SELECT 42 AS answer");
    r.select_result = JSON.stringify(
      table.toArray().map((row) => JSON.parse(JSON.stringify(row, (_k, v) => (typeof v === "bigint" ? Number(v) : v)))),
    );
    await conn.close();
    await db.terminate();
    worker.terminate();
    r.beam_post = await ping();
    return r;
  }, { stopBeam });
} catch (e) {
  failure = String(e).slice(0, 300);
}
await browser.close();
server.close();

if (failure || !out) {
  console.error(`sab_beam_verify failed: ${failure ?? "no result"}`);
  process.exit(1);
}
console.log(`build=${out.build ?? "none"}`);
console.log(`crossOriginIsolated=${out.crossOriginIsolated}`);
const beamAlive = out.beam_pre === true && out.beam_post === true;
console.log(`beam_alive=${beamAlive}`);
if (out.beam_error) console.error(`beam_error=${out.beam_error}`);
const ok = out.build === "duckdb-browser-coi" && out.crossOriginIsolated && beamAlive &&
  typeof out.select_result === "string" && out.select_result.includes("42");
if (ok) console.log(`select_result=${out.select_result}`);
process.exit(ok ? 0 : 1);
