# Popcorn worker memory budget decision (FNOX-SJ-WASM-2)

Standing: UNVERIFIED

Decision record, PENDING operator selection. No measurement has been run by the authoring lane.

## Evidence

- popcorn_actors/public/out/index.mjs:1409 enforces `maxMemory` between 64 MiB and 2 GiB, in 64 KiB
  multiples. A 32 MB budget (`beam.maxMemory "32M"`) is refused at construction.
- Measurement: `node popcorn_demo/scripts/worker_footprint.mjs` (5 runs; prints `worker_heap_bytes=<N>`
  per run and `worker_heap_bytes_max=<N>`). Metric is `measureUserAgentSpecificMemory` after init,
  an upper bound on the worker heap.

## Options

1. Accept the 64 MiB Popcorn minimum: `selected_budget=67108864` (valid only if worker_heap_bytes_max
   is at most 67108864).
2. Raise the budget to a higher 64 KiB-multiple value at or above worker_heap_bytes_max.

## To complete (operator + verifier)

Replace this section with the measured lines and the chosen budget, for example:

    worker_heap_bytes=<N from run>
    selected_budget=<value >= worker_heap_bytes_max and >= 67108864>

Until both lines exist, the acceptance grep prints nothing and this order stays UNKNOWN.
