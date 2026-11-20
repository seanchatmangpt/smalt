// COOP/COEP cross-origin-isolation witness (FNOX-SJ-WASM-1).
// Serves popcorn_demo/public with COOP/COEP, loads it in headless Chromium,
// evaluates self.crossOriginIsolated, reads the real HTTP response headers,
// and writes receipts/<UTC>-isolation.md only when isolation is observed.
// ISOLATION_WITNESS_STRIP_HEADERS=1: mutation, serve without the headers; must exit nonzero.
import { createServer, get } from "node:http";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require("playwright"));
} catch {
  ({ chromium } = require("/opt/homebrew/lib/node_modules/n8n/node_modules/playwright"));
}

const strip = process.env.ISOLATION_WITNESS_STRIP_HEADERS === "1";
const root = new URL("../public", import.meta.url).pathname;
const receiptsDir = new URL("../receipts", import.meta.url).pathname;
const FALLBACK_HTML = "<!doctype html><title>isolation-witness</title><body>ok</body>";

const server = createServer(async (req, res) => {
  const urlPath = req.url === "/" ? "/index.html" : req.url.split("?")[0];
  const headers = { "content-type": urlPath.endsWith(".html") ? "text/html" : "application/octet-stream" };
  if (!strip) {
    headers["cross-origin-opener-policy"] = "same-origin";
    headers["cross-origin-embedder-policy"] = "require-corp";
  }
  try {
    const body = await readFile(join(root, urlPath));
    res.writeHead(200, headers);
    res.end(body);
  } catch {
    if (urlPath === "/index.html") {
      res.writeHead(200, headers);
      res.end(FALLBACK_HTML);
    } else {
      res.writeHead(404).end("not found");
    }
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
const url = `http://127.0.0.1:${port}/index.html`;

// Real HTTP response headers, read over the wire.
const wire = await new Promise((resolve, reject) => {
  get(url, (res) => {
    res.resume();
    res.on("end", () => resolve(res.headers));
  }).on("error", reject);
});
const coop = wire["cross-origin-opener-policy"] ?? "";
const coep = wire["cross-origin-embedder-policy"] ?? "";

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
  console.error("no chromium headless shell or system Chrome found; run: npx playwright install chromium-headless-shell");
  server.close();
  process.exit(2);
}

const browser = await chromium.launch({ headless: true, executablePath: bin });
const page = await browser.newPage();
await page.goto(url);
const isolated = await page.evaluate(() => self.crossOriginIsolated === true);
await browser.close();
server.close();

console.log(`crossOriginIsolated=${isolated}`);
console.log(`Cross-Origin-Opener-Policy: ${coop}`);
console.log(`Cross-Origin-Embedder-Policy: ${coep}`);

const ok = isolated && coop === "same-origin" && coep === "require-corp";
if (!ok) {
  console.error(`isolation not observed (strip=${strip}); no receipt written`);
  process.exit(1);
}

const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
const receiptPath = join(receiptsDir, `${stamp}-isolation.md`);
await mkdir(receiptsDir, { recursive: true });
await writeFile(receiptPath, `# ${stamp} isolation witness

Standing: PASS

Subject: popcorn_demo COOP/COEP isolation witness (FNOX-SJ-WASM-1)
URL: ${url}
Browser: ${bin}

crossOriginIsolated=true
Cross-Origin-Opener-Policy: ${coop}
Cross-Origin-Embedder-Policy: ${coep}

Header surface only; production agents.fnox.io hosting out of scope.
`);
console.log(`receipt=${receiptPath}`);
