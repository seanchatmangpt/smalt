// Headless verification of the duckdb-wasm spike (SPIKE lane S14-G).
// Same playwright launch/discovery pattern as popcorn_demo/scripts/browser_smoke.mjs.
// Exits 0 iff the page reports all three queries; 1 otherwise.
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

const root = new URL(".", import.meta.url).pathname;
const MIME = {
  ".html": "text/html",
  ".mjs": "text/javascript",
  ".js": "text/javascript",
  ".json": "application/json",
  ".jsonl": "application/jsonl",
  ".wasm": "application/wasm",
};

const server = createServer(async (req, res) => {
  console.log("[req]", req.url);
  const urlPath = req.url === "/" ? "/index.html" : req.url;
  try {
    const body = await readFile(join(root, urlPath));
    const ext = urlPath.slice(urlPath.lastIndexOf("."));
    res.writeHead(200, { "content-type": MIME[ext] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end("not found: "+urlPath); console.log("[404]", urlPath);
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
console.log(`serving ${root} on 127.0.0.1:${port}`);

const { readdirSync, existsSync } = await import("node:fs");
const pwCache = process.env.HOME + "/Library/Caches/ms-playwright";
const shellBin =
  process.env.CHROMIUM_PATH ??
  (existsSync(pwCache)
    ? readdirSync(pwCache)
        .filter((d) => d.startsWith("chromium_headless_shell-"))
        .sort()
        .reverse()
        .map((d) => `${pwCache}/${d}/chrome-headless-shell-mac-arm64/chrome-headless-shell`)
        .find((p) => existsSync(p))
    : null);
const systemChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const resolvedBin =
  shellBin ?? (existsSync(systemChrome) ? systemChrome : null);
if (!resolvedBin) {
  console.error("no chromium found; run: npx playwright install chromium-headless-shell");
  process.exit(1);
}
const browser = await chromium.launch({ headless: true, executablePath: resolvedBin });
const page = await browser.newPage();
page.on("console", (m) => console.log("[console]", m.text().slice(0, 300)));
page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 300)));

await page.goto(`http://127.0.0.1:${port}/index.html`);

const TIMEOUT = 90_000;
const start = Date.now();
let status = null;
while (Date.now() - start < TIMEOUT) {
  status = await page.evaluate(() => document.querySelector("#status")?.textContent ?? null);
  if (status && status.includes("query3_ms")) break;
  await new Promise((r) => setTimeout(r, 500));
}

console.log("SPIKE_STATUS:\n" + status);
await browser.close();
server.close();
process.exit(status && status.includes("query3_ms") ? 0 : 1);
