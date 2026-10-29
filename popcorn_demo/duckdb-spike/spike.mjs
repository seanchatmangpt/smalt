// Minimal duckdb-wasm SPIKE: real SQL over popcorn_demo/bench/scvd.jsonl in the
// browser tab. Manual EH (non-SAB) worker bundle, all files local — no CDN.
// Timings are indicative, not a claim.
import * as duckdb from "./node_modules/@duckdb/duckdb-wasm/dist/duckdb-browser.mjs";

const el = (t) => (document.querySelector("#status").textContent += t + "\n");
document.querySelector("#status").textContent = "";

async function main() {
  el("build=duckdb-browser-eh (manual local bundle, no COOP/COEP required)");
  const bundle = {
    mainModule: "/node_modules/@duckdb/duckdb-wasm/dist/duckdb-eh.wasm",
    mainWorker: "./node_modules/@duckdb/duckdb-wasm/dist/duckdb-browser-eh.worker.js",
  };
  const worker = new Worker(bundle.mainWorker, { type: "module" });
  const db = new duckdb.AsyncDuckDB(new duckdb.ConsoleLogger(), worker);

  const t0 = performance.now();
  await db.instantiate(bundle.mainModule);
  el(`instantiate_ms=${(performance.now() - t0).toFixed(1)}`);

  // ingest: real jsonl -> JS objects -> duckdb table (auto CREATE TABLE from JSON)
  const text = await (await fetch("/scvd.jsonl")).text();
  const rows = text.trim().split("\n").map((l) => JSON.parse(l));
  el(`rows_ingested_js=${rows.length}`);

  const conn = await db.connect();
  const t1 = performance.now();
  const { tableFromArrays } = await import("apache-arrow");
  // flatten to scalar columns (drop nested "extra" object for the spike)
  const keys = [...new Set(rows.flatMap((r) => Object.keys(r).filter((k) => typeof r[k] !== "object" || r[k] === null)))];
  const arrays = Object.fromEntries(keys.map((k) => [k, rows.map((r) => r[k] ?? null)]));
  await conn.insertArrowTable(tableFromArrays(arrays), { name: "scvd", create: true });
  const insertMs = (performance.now() - t1).toFixed(1);
  el(`insert_ms=${insertMs}`);

  const run = async (sql) => {
    const t = performance.now();
    const r = await conn.query(sql);
    return {
      ms: +(performance.now() - t).toFixed(2),
      rows: r.toArray().map((row) => JSON.parse(JSON.stringify(row, (_k, v) => (typeof v === "bigint" ? Number(v) : v)))),
    };
  };

  const q1 = await run("SELECT phase, count(*) AS n FROM scvd GROUP BY phase ORDER BY n DESC");
  el(`query1_ms=${q1.ms} count_by_phase=${JSON.stringify(q1.rows)}`);

  const q2 = await run("SELECT n, median(vm_wall_ms) AS median_wall_ms FROM scvd GROUP BY n ORDER BY n");
  el(`query2_ms=${q2.ms} median_wall_by_n=${JSON.stringify(q2.rows)}`);

  const q3 = await run("SELECT max(p99_us) AS max_p99_us FROM scvd");
  el(`query3_ms=${q3.ms} max_p99=${JSON.stringify(q3.rows)}`);

  window.__spike = { q1, q2, q3, rows: rows.length };
}

main().catch((e) => el("SPIKE_ERROR: " + String(e).slice(0, 500)));
