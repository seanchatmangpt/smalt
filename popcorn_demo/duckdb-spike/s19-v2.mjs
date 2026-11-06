// S19-V2 bytes-path fidelity court (lane S19-V2, v2 rung).
// Extends the landed v0 pattern (verify.mjs): same playwright/chromium launch,
// same corpus fixture, same ratio-fence law. What v2 ADDS:
//   1. Typed bytes-path fidelity fence — the JS flatten projects SCALAR columns
//      only (same column set as the native v1a read_json_auto scalar surface);
//      the fence FAILS CLOSED unless (a) every projected column is declared,
//      (b) the dropped-key set is exactly the set of nested (object-valued)
//      keys — i.e. the drop is typed and named, never silent, and (c) the
//      wasm-SQL result and the JS scalar baseline agree over that IDENTICAL
//      column set.
//   2. Same corpus scvd.jsonl + sha256 embed + population fence (rows >= 1).
//   3. Same ratio fence law: SQL_p99_us_median <= 10x scalar_p99_us_median,
//      N=10 measured-then-fenced, 3 runs, median-reported, bench_emit jsonl.
// No Process.sleep — the deadline-checked 500ms status poll below is the
// sanctioned pattern (bounded poll on a real observable).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { createRequire } from "node:module";
import { createHash } from "node:crypto";

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
  const urlPath = req.url === "/" ? "/index.html" : req.url;
  try {
    const body = await readFile(join(root, urlPath));
    const ext = urlPath.slice(urlPath.lastIndexOf("."));
    res.writeHead(200, {
      "content-type": MIME[ext] ?? "application/octet-stream",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
    res.end(body);
  } catch {
    res.writeHead(404).end("not found: " + urlPath);
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
console.log(`serving ${root} on 127.0.0.1:${port}`);

// --- fixture: corpus sha256 embed + population fence (host side) ------------
const CORPUS_PATH = join(root, "scvd.jsonl");
const CORPUS_SHA256 = createHash("sha256").update(await readFile(CORPUS_PATH)).digest("hex");
const corpusText = await readFile(CORPUS_PATH, "utf8");
const corpusRows = corpusText.trim().split("\n").map((l) => JSON.parse(l));
if (!(corpusRows.length >= 1)) {
  console.error("POPULATION_FENCE_REFUSED: zero corpus rows (host side)");
  process.exit(1);
}
console.log(`corpus_rows=${corpusRows.length} corpus_sha256=${CORPUS_SHA256}`);

// Declared scalar projection (the fidelity fence's declared column set).
// Mirrors the native v1a rung's scalar surface; nested keys are named, not
// silently dropped.
const nestedKeys = [
  ...new Set(
    corpusRows.flatMap((r) =>
      Object.keys(r).filter((k) => typeof r[k] === "object" && r[k] !== null),
    ),
  ),
];
const scalarKeys = [
  ...new Set(corpusRows.flatMap((r) => Object.keys(r).filter((k) => typeof r[k] !== "object" || r[k] === null))),
];
console.log(`declared_scalar_columns=${JSON.stringify(scalarKeys)}`);
console.log(`declared_dropped_nested_keys=${JSON.stringify(nestedKeys)}`);
if (nestedKeys.length === 0 && scalarKeys.length === 0) {
  console.error("FIDELITY_FENCE_REFUSED: empty projection");
  process.exit(1);
}

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
const resolvedBin = shellBin ?? (existsSync(systemChrome) ? systemChrome : null);
if (!resolvedBin) {
  console.error("no chromium found; run: npx playwright install chromium-headless-shell");
  process.exit(1);
}
let browser;
try {
  browser = await chromium.launch({ headless: true, executablePath: resolvedBin, timeout: 30_000 });
} catch (e) {
  console.error(`CHROMIUM_LAUNCH_BLOCKED: ${String(e).slice(0, 400)}`);
  server.close();
  process.exit(3); // typed BLOCKED-environmental exit
}
const page = await browser.newPage();
page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 300)));

await page.goto(`http://127.0.0.1:${port}/index.html`);

const TIMEOUT = 90_000;
const start = performance.now();
let status = null;
while (performance.now() - start < TIMEOUT) {
  status = await page.evaluate(() => document.querySelector("#status")?.textContent ?? null);
  if (status && status.includes("query3_ms")) break;
  await new Promise((r) => setTimeout(r, 500)); // sanctioned deadline-checked status poll
}
console.log("SPIKE_STATUS:\n" + status);
if (!status || !status.includes("query3_ms")) {
  console.error("SPIKE_TIMEOUT_BLOCKED: page never reached query3_ms within deadline");
  await browser.close();
  server.close();
  process.exit(3);
}

const ITER_SCALAR = 500;
const ITER_SQL = 100;
const WARMUP_SQL = 5;

const courtRun = () =>
  page.evaluate(
    async ({ ITER_SCALAR, ITER_SQL, WARMUP_SQL, scalarKeys, nestedKeys }) => {
      const t = () => performance.now();
      const p99 = (xs) => xs.slice().sort((a, b) => a - b)[Math.ceil(0.99 * xs.length) - 1];
      const median = (xs) => {
        const s = xs.slice().sort((a, b) => a - b);
        const m = s.length >> 1;
        return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
      };
      const norm = (x) => JSON.stringify(x, (_k, v) => (typeof v === "bigint" ? Number(v) : v));

      const rows = (await (await fetch("/scvd.jsonl")).text())
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));
      if (!(rows.length >= 1)) throw new Error("POPULATION_FENCE: zero rows");

      // --- FIDELITY FENCE (in-page, fail-closed) ---------------------------
      // (a) the projection is exactly the declared scalar column set
      const obsScalar = [
        ...new Set(rows.flatMap((r) => Object.keys(r).filter((k) => typeof r[k] !== "object" || r[k] === null))),
      ].sort();
      const obsNested = [
        ...new Set(rows.flatMap((r) => Object.keys(r).filter((k) => typeof r[k] === "object" && r[k] !== null))),
      ].sort();
      const scalarDeclared = norm(obsScalar) === norm([...scalarKeys].sort());
      const droppedIsNested = norm(obsNested) === norm([...nestedKeys].sort());
      const droppedCount = obsNested.length;
      if (!scalarDeclared) throw new Error("FIDELITY_FENCE: scalar projection != declared set");
      if (!droppedIsNested) throw new Error("FIDELITY_FENCE: dropped keys != declared nested set");

      // --- scalar baseline over the SAME declared column set ---------------
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

      // --- wasm SQL leg (fresh duckdb-wasm instance per run) ----------------
      const duck = await import("/node_modules/@duckdb/duckdb-wasm/dist/duckdb-browser.mjs");
      const bundle = {
        mainModule: "/node_modules/@duckdb/duckdb-wasm/dist/duckdb-eh.wasm",
        mainWorker: "./node_modules/@duckdb/duckdb-wasm/dist/duckdb-browser-eh.worker.js",
      };
      const worker = new Worker(bundle.mainWorker, { type: "module" });
      const db = new duck.AsyncDuckDB(new duck.ConsoleLogger(), worker);
      await db.instantiate(bundle.mainModule);
      const conn = await db.connect();
      const { tableFromArrays } = await import("apache-arrow");
      // bytes path: JS flatten -> Arrow table over the DECLARED scalar columns
      // only (nested keys typed-dropped, fenced above)
      const arrays = Object.fromEntries(scalarKeys.map((k) => [k, rows.map((r) => r[k] ?? null)]));
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

      const agree = {
        op1: norm(q1.rows) === norm(s1),
        op2: norm(q2.rows) === norm(s2),
        op3: norm(q3.rows) === norm([{ max_p99_us: s3 }]),
      };
      const stat = (times) => ({
        p50: +(median(times) * 1000).toFixed(3),
        p99: +(p99(times) * 1000).toFixed(3),
      });
      return {
        rows: rows.length,
        fidelity: { scalar_declared: scalarDeclared, dropped_is_nested: droppedIsNested, dropped_keys: obsNested, dropped_count: droppedCount, scalar_column_count: obsScalar.length },
        scalar: { op1: stat(scalarTimes.op1), op2: stat(scalarTimes.op2), op3: stat(scalarTimes.op3) },
        sql: { op1: stat(sqlTimes.op1), op2: stat(sqlTimes.op2), op3: stat(sqlTimes.op3) },
        agree,
      };
    },
    { ITER_SCALAR, ITER_SQL, WARMUP_SQL, scalarKeys, nestedKeys },
  );

const OPS = ["op1", "op2", "op3"];
const OP_NAMES = { op1: "count_by_phase", op2: "median_vm_wall_ms_by_n", op3: "max_p99_us" };
const RATIO_FENCE = 10;

const runs = [];
for (let r = 0; r < 3; r++) {
  const out = await courtRun();
  runs.push(out);
  console.log(
    `court run ${r + 1}/3: rows=${out.rows} fidelity=${JSON.stringify(out.fidelity)} ` +
      OPS.map((o) => `${o} sql_p99=${out.sql[o].p99}us scalar_p99=${out.scalar[o].p99}us`).join(" "),
  );
}

// fail-closed fences on the measured runs
if (runs.some((x) => !(x.rows >= 1))) {
  console.error("POPULATION_FENCE_REFUSED: a run reported zero rows");
  await browser.close(); server.close(); process.exit(1);
}
if (runs.some((x) => !x.fidelity.scalar_declared || !x.fidelity.dropped_is_nested)) {
  console.error("FIDELITY_FENCE_REFUSED: a run's projection drifted from the declared column set");
  await browser.close(); server.close(); process.exit(1);
}

const med = (xs) => {
  const s = xs.slice().sort((a, b) => a - b);
  return s[s.length >> 1];
};
const { appendFile } = await import("node:fs/promises");
const benchFile = process.env.BENCH_S19_FILE ?? "/Users/sac/smalt/popcorn_demo/bench/bench-s19-v2.jsonl";
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
    lane: "s19-v2",
    claim_id: "S19-C2",
    op: OP_NAMES[o],
    corpus_sha256: CORPUS_SHA256,
    corpus_rows: runs[0].rows,
    runs: 3,
    fidelity_projection: "scalar_columns_only",
    declared_scalar_columns: runs[0].fidelity.scalar_column_count,
    dropped_nested_keys: runs[0].fidelity.dropped_keys,
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
console.log(`S19_C2_VERDICT=${allPass ? "PASS" : "REFUTED"}`);

await browser.close();
server.close();
process.exit(allPass ? 0 : 1);
