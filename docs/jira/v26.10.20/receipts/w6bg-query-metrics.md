# Receipt — w6bg: Cosmos query-metrics + request-charge parity

**Standing: ALIVE** (module tier; strict full-tree compile green, real-output witness)

**Date**: 2026-10-20
**Lane**: w6bg (wave-6, v26.10.20)
**Subject**: additive query-engine instrumentation — gated `x-ms-documentdb-query-metrics` header + GET-container `x-ms-request-charge` emulation

## What landed

1. **`lib/smalt/data_plane/cosmos_query_metrics.ex`** (NEW, ~95 lines) — pure codec:
   - `gated?/1` — metrics ride the response ONLY when the client sent
     `x-ms-documentdb-query: true` (real-Cosmos parity: header-gated).
   - `metrics_json/5` — the Azure `x-ms-documentdb-query-metrics` shape
     (Retrieved/Output counts+sizes, IndexHitRatio honest `0.0` — the emulator
     has no index, documented not faked; QueryPreparationTimes.CompileTime and
     QueryExecutionTime/DocumentLoadTime are REAL monotonic `:timer.tc`
     measurements of the engine's actual parse/eval/fetch stages).
   - `request_charge/1` — GET container `x-ms-request-charge` emulation:
     **2.5 flat + 0.1 per KB scanned** (emulation constants documented here;
     the emulator has no RU accounting).
   - `doc_bytes/1` — term_to_binary byte size of a stored doc.
2. **`lib/smalt/data_plane/cosmos.ex`** (additive, 3 instrumented stages):
   - `do_query_docs/5`: parse wrapped in `:timer.tc` → prep_ms threaded to
     `scan_query_docs/5` (new defaulted 5th arg; existing 3/4-arg call sites
     untouched).
   - `scan_query_docs`: fetch wrapped in `:timer.tc` (ret_us), scanned set
     captured post-pk-scope PRE-projection, eval wrapped in `:timer.tc`
     (exec_us), gated metrics header merged into the response headers.
   - `query_metrics_headers/6` private helper: ungated → `{}` (no header).
3. **`lib/smalt/egress/CosmosRoutes.ex`** (additive): GET `/dbs/:db/colls/:coll`
   overrides `x-ms-request-charge` with `2.5 + 0.1/KB` over the REAL container
   bytes (per-doc `doc_bytes/1` sum → `request_charge/1`).

## Verification (real output, replay: `MIX_BUILD_ROOT=_build-lane-w6bg MIX_ENV=test mix run --no-start tmp/w6bg_witness.exs`)

```
STORE-UP
SEEDED=5
F2_GATED_METRICS=ok count=5 out=3
F3_UNGATED_NO_METRICS=0 → no metrics header
F4_REQUEST_CHARGE=ok bytes=1250 charge=2.62
W6BG WITNESS: ALL FACES OK
```

- F2: gated query `SELECT * FROM c WHERE c.n >= 3` over 5 stored docs →
  metrics header present with **RetrievedDocumentCount=5, OutputDocumentCount=3,
  RetrievedDocumentSize=1250, OutputDocumentSize=736** — byte-computed against
  the stored representation (server `_ts`/`_etag` included), not the seed
  literals; QueryExecutionTime/CompileTime/DocumentLoadTime are real
  monotonic measurements of the actual engine stages.
- F3: identical query ungated → **no** metrics header (the header is gated,
  real parity).
- F4: request-charge over the real 1250 container bytes → `2.5 + 0.1·1250/1024
  = 2.62` — formula-exact.

## Strict gate

`MIX_BUILD_ROOT=_build-lane-w6bg MIX_ENV=test mix compile --warnings-as-errors`
→ **exit 0, 0 warnings, 0 errors** (full tree, includes my diff).

## Non-vacuity / falsifier

- The F3 leg (ungated → no header) proves the gate is real — a gate that
  emitted metrics unconditionally would fail it.
- F2 asserts byte-exact counts/sizes against an independently computed
  expectation from the STORED docs — green under wrong counts/sizes would be
  vacuous.
- Falsifier: green under a broken gate or wrong sizes would be vacuous;
  re-run the replay command on the quiesced tree to re-derive.

## Notes

- Query engine itself untouched — all wiring additive (3 instrumented stages,
  1 private helper, 1 route-charge override).
- Foreign landing en route: a sibling lane qualified my
  `ConditionalHeaders.header` call to `Smalt.DataPlane.ConditionalHeaders` in
  the new module (compile-freeze SLA, disclosed) — kept, correct.
- No mocks, no `Process.sleep` (bounded polls only). No git operations.
