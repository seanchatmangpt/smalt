// Static server for the duckdb-wasm spike (same pattern as scripts/browser_smoke.mjs).
// Serves the spike dir WITHOUT COOP/COEP: the EH (non-SAB) duckdb-wasm build
// does not require them (verified by this run; OPFS/COI builds would).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const root = new URL(".", import.meta.url).pathname;
const MIME = {
  ".html": "text/html",
  ".mjs": "text/javascript",
  ".js": "text/javascript",
  ".json": "application/json",
  ".jsonl": "application/json",
  ".wasm": "application/wasm",
};

createServer(async (req, res) => {
  const urlPath = req.url === "/" ? "/index.html" : req.url;
  try {
    const body = await readFile(join(root, urlPath));
    res.writeHead(200, {
      "content-type": MIME[urlPath.slice(urlPath.lastIndexOf("."))] ?? "application/octet-stream",
    });
    res.end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
}).listen(Number(process.env.PORT ?? 8931), "127.0.0.1", () =>
  console.log(`serving ${root} on 127.0.0.1:${process.env.PORT ?? 8931}`)
);
