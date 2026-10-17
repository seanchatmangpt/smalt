// Popcorn in-browser smoke witness: serves public/out with COOP/COEP headers,
// boots the wasm BEAM in headless Chromium, waits for the Elixir smoke Task
// to report through Popcorn.JS into #status.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, extname } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require("playwright"));
} catch {
  ({ chromium } = require("/opt/homebrew/lib/node_modules/n8n/node_modules/playwright"));
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

const browser = await chromium.launch({ headless: true, executablePath: process.env.HOME + "/Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell" });
const page = await browser.newPage();
page.on("console", (m) => console.log("[console]", m.text().slice(0, 300)));
page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 300)));

await page.setContent? null : null;
await page.goto(`http://127.0.0.1:${port}/index.html`);

const TIMEOUT = 90_000;
const start = Date.now();
let receipt = null;
while (Date.now() - start < TIMEOUT) {
  receipt = await page.evaluate(() => document.querySelector("#status")?.textContent ?? null);
  if (receipt && receipt !== "Starting Popcorn...") break;
  await new Promise((r) => setTimeout(r, 500));
}

console.log("SMOKE_RECEIPT:", receipt);
await browser.close();
server.close();
process.exit(receipt && receipt.includes("=OK") ? 0 : 1);
