# WASM-2 worker footprint and budget selection

Standing: PARTIAL_ALIVE

Subject: /Users/sac/smalt popcorn_demo/scripts/worker_footprint.mjs, system Google Chrome (headless), Popcorn from popcorn_actors/public/out.

Measurement (5 runs, max_memory=64M, performance.measureUserAgentSpecificMemory):

worker_heap_bytes=91425870
worker_heap_bytes=91429692
worker_heap_bytes=91426026
worker_heap_bytes=91432288
worker_heap_bytes=91433052
worker_heap_bytes_max=91433052

Same figure at max_memory=128M (91427432) and at 32M (91432728): the footprint does not vary with the
beam.maxMemory option on this init path.

Ruling (decisions/PANEL-RULINGS-2026-11-19.md, panel 20/20, rule "A unless measured heap > ~48 MiB, then C"):
measured 91433052 B (87.2 MiB) exceeds 48 MiB, so Option C applies.

selected_budget=134217728

Not witnessed: the order's Step 1 refusal. Popcorn.init with --max-memory 32M exits 0 here (init accepted,
heap measured), although index.mjs:1409 carries the typed bound text. The headless-shell Chromium lacks
measureUserAgentSpecificMemory, so measurement needs full Chrome.
