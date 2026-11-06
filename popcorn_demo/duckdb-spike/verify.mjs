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
    // COOP/COEP -> crossOriginIsolated -> unclamped performance.now (µs
    // resolution). Without it Chrome quantizes timers to 0.1ms and the µs-scale
    // scalar baseline reads as 0. The EH wasm build runs fine under COI.
    res.writeHead(200, {
      "content-type": MIME[ext] ?? "application/octet-stream",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
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

// ---------------------------------------------------------------------------
// S19-V0 census court: independent sleep-free scalar baseline (plain JS
// group-by over the SAME corpus rows, NO duckdb) measured in the SAME run as
// the duckdb-wasm SQL leg. 3-run loop, median-reported, RATIO fence
// (SQL_p99 <= 10x scalar_p99 — the multiple named in the plan, never an
// absolute ms bound). Population fence: row count >= 1 before any fence.
// BENCH_SPEC §3/§4 shape. No Process.sleep anywhere below.
// ---------------------------------------------------------------------------
const CORPUS_SHA256 = (await import("node:crypto"))
  .createHash("sha256")
  .update(await readFile(join(root, "scvd.jsonl")))
  .digest("hex");
console.log(`corpus_sha256=${CORPUS_SHA256}`);

const ITER_SCALAR = 500; // iterations per op, scalar baseline
const ITER_SQL = 100; // iterations per op, duckdb SQL
const WARMUP_SQL = 5;

// Runs inside the page. importmap resolves apache-arrow/tslib/flatbuffers.
const courtRun = () =>
  page.evaluate(
    async ({ ITER_SCALAR, ITER_SQL, WARMUP_SQL }) => {
      const t = () => performance.now();
      const p99 = (xs) =>
        xs.slice().sort((a, b) => a - b)[Math.ceil(0.99 * xs.length) - 1];
      const median = (xs) => {
        const s = xs.slice().sort((a, b) => a - b);
        const m = s.length >> 1;
        return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
      };

      // same rows the SQL leg ingests (verbatim corpus, 46 lines)
      const rows = (await (await fetch("/scvd.jsonl")).text())
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));
      if (!(rows.length >= 1)) throw new Error("POPULATION_FENCE: zero rows");

      // --- scalar ops (plain JS, no duckdb) -------------------------------
      const scalarCountByPhase = () => {
        const m = new Map();
        for (const r of rows) m.set(r.phase, (m.get(r.phase) ?? 0) + 1);
        return [...m].map(([phase, n]) => ({ phase, n })).sort((a, b) => b.n - a.n);
      };
      const scalarMedianWallByN = () => {
        const g = new Map();
        for (const r of rows) {
          if (!g.has(r.n)) g.set(r.n, []);
          g.get(r.n).push(r.vm_wall_ms);
        }
        return [...g]
          .map(([n, xs]) => {
            xs.sort((a, b) => a - b);
            const i = xs.length >> 1;
            return { n, median_wall_ms: xs.length % 2 ? xs[i] : (xs[i - 1] + xs[i]) / 2 };
          })
          .sort((a, b) => a.n - b.n);
      };
      // duckdb max() ignores NULLs; rows without p99_us must be skipped, not
      // coerced to NaN via Math.max(-Infinity, undefined)
      const scalarMaxP99 = () =>
        rows.reduce(
          (m, r) => (r.p99_us === undefined || r.p99_us === null ? m : Math.max(m, r.p99_us)),
          -Infinity,
        );

      const scalarTimes = { op1: [], op2: [], op3: [] };
      let s1, s2, s3;
      for (let i = 0; i < ITER_SCALAR; i++) {
        let a = t(); s1 = scalarCountByPhase(); scalarTimes.op1.push(t() - a);
        a = t(); s2 = scalarMedianWallByN(); scalarTimes.op2.push(t() - a);
        a = t(); s3 = scalarMaxP99(); scalarTimes.op3.push(t() - a);
      }

      // --- SQL leg (fresh duckdb-wasm instance per run) --------------------
      const duck = await import(
        "/node_modules/@duckdb/duckdb-wasm/dist/duckdb-browser.mjs"
      );
      const bundle = {
        mainModule: "/node_modules/@duckdb/duckdb-wasm/dist/duckdb-eh.wasm",
        mainWorker: "./node_modules/@duckdb/duckdb-wasm/dist/duckdb-browser-eh.worker.js",
      };
      const worker = new Worker(bundle.mainWorker, { type: "module" });
      const db = new duck.AsyncDuckDB(new duck.ConsoleLogger(), worker);
      await db.instantiate(bundle.mainModule);
      const conn = await db.connect();
      const { tableFromArrays } = await import("apache-arrow");
      const keys = [
        ...new Set(
          rows.flatMap((r) => Object.keys(r).filter((k) => typeof r[k] !== "object" || r[k] === null)),
        ),
      ];
      const arrays = Object.fromEntries(keys.map((k) => [k, rows.map((r) => r[k] ?? null)]));
      await conn.insertArrowTable(tableFromArrays(arrays), { name: "scvd", create: true });

      const runSql = async (sql) => {
        const a = t();
        const r = await conn.query(sql);
        return {
          ms: t() - a,
          rows: r.toArray().map((row) =>
            JSON.parse(JSON.stringify(row, (_k, v) => (typeof v === "bigint" ? Number(v) : v))),
          ),
        };
      };
      const SQL = {
        op1: "SELECT phase, count(*) AS n FROM scvd GROUP BY phase ORDER BY n DESC",
        op2: "SELECT n, median(vm_wall_ms) AS median_wall_ms FROM scvd GROUP BY n ORDER BY n",
        op3: "SELECT max(p99_us) AS max_p99_us FROM scvd",
      };
      const sqlTimes = { op1: [], op2: [], op3: [] };
      let q1, q2, q3;
      for (let i = 0; i < WARMUP_SQL + ITER_SQL; i++) {
        const w = i < WARMUP_SQL;
        const r1 = await runSql(SQL.op1); if (w) continue; sqlTimes.op1.push(r1.ms); q1 = r1;
        const r2 = await runSql(SQL.op2); if (w) continue; sqlTimes.op2.push(r2.ms); q2 = r2;
        const r3 = await runSql(SQL.op3); if (w) continue; sqlTimes.op3.push(r3.ms); q3 = r3;
      }
      await conn.close();
      await db.terminate();
      worker.terminate();

      const norm = (x) => JSON.stringify(x, (_k, v) => (typeof v === "bigint" ? Number(v) : v));
      const agree = {
        op1: norm(q1.rows) === norm(s1),
        op2: norm(q2.rows) === norm(s2),
        op3: norm(q3.rows) === norm([{ max_p99_us: s3 }]),
      };
      // timings reported in MICROSECONDS — ms rounding collapses the µs-scale
      // scalar ops to 0 and turns the ratio fence into Infinity-vs-zero
      const stat = (times) => ({
        p50: +(median(times) * 1000).toFixed(3),
        p99: +(p99(times) * 1000).toFixed(3),
      });
      return {
        rows: rows.length,
        scalar: { op1: stat(scalarTimes.op1), op2: stat(scalarTimes.op2), op3: stat(scalarTimes.op3) },
        sql: { op1: stat(sqlTimes.op1), op2: stat(sqlTimes.op2), op3: stat(sqlTimes.op3) },
        agree,
        results: { q3: q3.rows, scalar_op3: s3 },
      };
    },
    { ITER_SCALAR, ITER_SQL, WARMUP_SQL },
  );

const OPS = ["op1", "op2", "op3"];
const OP_NAMES = {
  op1: "count_by_phase",
  op2: "median_vm_wall_ms_by_n",
  op3: "max_p99_us",
};
const RATIO_FENCE = 10; // SQL_p99 <= 10x scalar_p99 (named multiple, no absolute ms)

const runs = [];
for (let r = 0; r < 3; r++) {
  const out = await courtRun();
  runs.push(out);
  console.log(
    `court run ${r + 1}/3: rows=${out.rows} agree=${JSON.stringify(out.agree)} ` +
      OPS.map((o) => `${o} sql_p99=${out.sql[o].p99}us scalar_p99=${out.scalar[o].p99}us`).join(" "),
  );
}

// population fence re-checked on the measured runs, fail-closed
if (runs.some((x) => !(x.rows >= 1))) {
  console.error("POPULATION_FENCE_REFUSED: a run reported zero rows");
  await browser.close();
  server.close();
  process.exit(1);
}

const med = (xs) => {
  const s = xs.slice().sort((a, b) => a - b);
  return s[s.length >> 1];
};
const { appendFile } = await import("node:fs/promises");
const benchFile = process.env.BENCH_S19_FILE ?? "/Users/sac/smalt/popcorn_demo/bench/bench-s19.jsonl";
const ts = new Date().toISOString();
const rowsOut = [];
let allPass = true;
for (const o of OPS) {
  const sqlP99s = runs.map((x) => x.sql[o].p99);
  const scP99s = runs.map((x) => x.scalar[o].p99);
  const sqlMed = med(sqlP99s);
  const scMed = med(scP99s);
  const ratio = +(sqlMed / scMed).toFixed(4);
  const agree = runs.every((x) => x.agree[o]);
  const pass = ratio <= RATIO_FENCE && agree;
  allPass = allPass && pass;
  rowsOut.push({
    lane: "s19-v0",
    claim_id: "S19-C1",
    op: OP_NAMES[o],
    corpus_sha256: CORPUS_SHA256,
    corpus_rows: runs[0].rows,
    runs: 3,
    sql_p99_us_raw: sqlP99s,
    scalar_p99_us_raw: scP99s,
    sql_p99_us_median: sqlMed,
    scalar_p99_us_median: scMed,
    ratio_sql_over_scalar: ratio,
    fence: `sql_p99_us_median <= ${RATIO_FENCE} * scalar_p99_us_median`,
    results_agree_sql_vs_scalar: agree,
    errors: agree ? 0 : 1,
    verdict: pass ? "PASS" : "REFUTED",
    ts,
  });
  console.log(
    `${OP_NAMES[o]}: sql_p99_median=${sqlMed}us scalar_p99_median=${scMed}us ` +
      `ratio=${ratio}x fence(<=10x)=${pass ? "PASS" : "REFUTED"} agree=${agree}`,
  );
}
await appendFile(benchFile, rowsOut.map((r) => JSON.stringify(r)).join("\n") + "\n");
console.log(`emitted ${rowsOut.length} rows -> ${benchFile}`);
console.log(`S19_C1_VERDICT=${allPass ? "PASS" : "REFUTED"}`);

await browser.close();
server.close();
process.exit(status && status.includes("query3_ms") && allPass ? 0 : 1);
