// Read-only Popcorn worker footprint measurement (FNOX-SJ-WASM-2).
//
//   node popcorn_demo/scripts/worker_footprint.mjs                  -> 5 runs, prints worker_heap_bytes=<N> per run
//                                                                      and worker_heap_bytes_max=<N>
//   node popcorn_demo/scripts/worker_footprint.mjs --max-memory 32M -> boots real Popcorn with beam.maxMemory 32M;
//                                                                      expected nonzero exit + typed check() error
//   --runs <n> overrides the run count (default 5); --max-memory <NM|NG> sets beam.maxMemory (default 64M).
//
// Metric: performance.measureUserAgentSpecificMemory().bytes (requires cross-origin
// isolation, which this server provides via COOP/COEP) taken after Popcorn.init()
// resolves. It covers the page plus its dedicated workers including the BEAM wasm
// linear memory, so it is an upper bound on the worker's own heap, not a worker-only
// figure. The script writes no files; the budget receipt is authored separately.
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

const argv = process.argv.slice(2);
const argVal = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const maxMemory = argVal("--max-memory", "64M");
const runs = Number(argVal("--runs", "5"));

const root = new URL("../public", import.meta.url).pathname;
const mime = (p) =>
  p.endsWith(".html") ? "text/html"
  : p.endsWith(".mjs") || p.endsWith(".js") ? "text/javascript"
  : p.endsWith(".json") ? "application/json"
  : p.endsWith(".wasm") ? "application/wasm"
  : "application/octet-stream";
const server = createServer(async (req, res) => {
  const urlPath = (req.url === "/" ? "/index.html" : req.url).split("?")[0];
  try {
    const body = await readFile(join(root, urlPath));
    res.writeHead(200, {
      "content-type": mime(urlPath),
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
    res.end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

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
const bin = shellBin ?? (existsSync(systemChrome) ? systemChrome : null);
if (!bin) {
  console.error("no chromium headless shell or system Chrome found");
  server.close();
  process.exit(1);
}

async function measureOnce() {
  const browser = await chromium.launch({ headless: true, executablePath: bin });
  try {
    const page = await browser.newPage();
    // Blank isolated page; the app.js smoke legs are deliberately not loaded.
    await page.goto(`http://127.0.0.1:${port}/out/otp/manifest.json`);
    return await page.evaluate(async ({ port, maxMemory }) => {
      const { Popcorn } = await import(`http://127.0.0.1:${port}/out/index.mjs`);
      try {
        const p = await Popcorn.init({
          beam: { maxMemory },
          workerUrl: `http://127.0.0.1:${port}/out/worker.mjs`,
        });
        let bytes = null;
        let source = "measureUserAgentSpecificMemory";
        let measureError = null;
        if (self.crossOriginIsolated && performance.measureUserAgentSpecificMemory) {
          try {
            bytes = (await performance.measureUserAgentSpecificMemory()).bytes;
          } catch (e) {
            measureError = String(e && e.message ? e.message : e);
            source = "unavailable";
          }
        } else {
          source = "unavailable";
        }
        return { ok: true, bytes, source, measureError, isolated: self.crossOriginIsolated, popcorn: !!p };
      } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
      }
    }, { port, maxMemory });
  } finally {
    await browser.close();
  }
}

let exit = 0;
const heaps = [];
try {
  for (let i = 0; i < runs; i++) {
    const r = await measureOnce();
    if (!r.ok) {
      console.error(`init_error=${r.error}`);
      console.log(`max_memory=${maxMemory} init=REFUSED`);
      exit = 1;
      break;
    }
    if (r.bytes == null) {
      console.error(`measurement unavailable (isolated=${r.isolated}) ${r.measureError ?? ""}`);
      console.log(`max_memory=${maxMemory} init=ACCEPTED measurement=UNAVAILABLE`);
      exit = 1;
      break;
    }
    heaps.push(r.bytes);
    console.log(`worker_heap_bytes=${r.bytes} run=${i + 1} max_memory=${maxMemory} source=${r.source}`);
  }
  if (exit === 0) console.log(`worker_heap_bytes_max=${Math.max(...heaps)}`);
} finally {
  server.close();
}
process.exit(exit);
