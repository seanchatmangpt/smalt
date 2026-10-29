# RECEIPT: duckdb-wasm in-browser spike (lane S14-G)

Standing: SPIKE-ALIVE

## What ran (verbatim, exit 0)

`node verify.mjs` (headless chromium-headless-shell, 2026-10-20).
Full log: `run-output.txt` (same dir).

    SPIKE_STATUS:
    build=duckdb-browser-eh (manual local bundle, no COOP/COEP required)
    instantiate_ms=387.6
    rows_ingested_js=46
    insert_ms=28.6
    query1_ms=20.3 count_by_phase=[{"phase":"ramp","n":39},{"phase":"contention","n":6},{"phase":"baseline","n":1}]
    query2_ms=3.2 median_wall_by_n=[{"n":1,"median_wall_ms":2.4},{"n":2,"median_wall_ms":3.2},{"n":4,"median_wall_ms":2.8},{"n":8,"median_wall_ms":2.8},{"n":16,"median_wall_ms":2.8},{"n":32,"median_wall_ms":2.15},{"n":64,"median_wall_ms":5.4},{"n":128,"median_wall_ms":2.95},{"n":256,"median_wall_ms":6.2},{"n":512,"median_wall_ms":14.1},{"n":1024,"median_wall_ms":36.5},{"n":2048,"median_wall_ms":77.2},{"n":4096,"median_wall_ms":295.1}]
    query3_ms=1.4 max_p99=[{"max_p99_us":36759}]
    EXIT=0

## What this proves

- duckdb-wasm (@duckdb/duckdb-wasm@1.29.0 pinned, 154 MB node_modules incl.
  deps) instantiates and executes real SQL in a headless browser tab against
  the real corpus `popcorn_demo/bench/scvd.jsonl` (46 rows, copied verbatim
  to this dir as `scvd.jsonl`).
- Build used: **EH (non-SAB) worker build**
  (`duckdb-eh.wasm` + `duckdb-browser-eh.worker.js`), served locally from
  node_modules — manual bundle, no CDN. This build does NOT require
  COOP/COEP headers — verified: the spike server sends none and the run
  passes. OPFS/COI builds would.
- Ingest path: jsonl → JS objects (46) → Apache Arrow table (scalar columns;
  nested `extra` object dropped for the spike) →
  `insertArrowTable(name=scvd, create=true)` → three real SQL queries in the
  same tab (count by phase; median vm_wall_ms by n; max p99_us).

## Timings (indicative, from the exit-0 run above)

| op | ms |
|---|---|
| instantiate wasm | 387.6 |
| insert (46 rows via Arrow) | 28.6 |
| query1 count-by-phase | 20.3 (first-query warmup) |
| query2 median(vm_wall_ms) by n | 3.2 |
| query3 max(p99_us) | 1.4 |

## What this does NOT prove

- Does NOT prove SharedArrayBuffer zero-copy BEAM↔duckdb transfer (EH build
  does not use SAB at all; no BEAM was in the tab). It proves duckdb-wasm
  runs and queries our real data in the same tab.
- No throughput/scaling/production claims — typed SPIKE, not a bench result.
