# Receipt: w6s — Application Insights Breeze ingest emulation

- **Lane**: w6s (wave-6)
- **Date**: 2026-10-20
- **Standing**: PARTIAL_ALIVE (module faces witnessed; wire tier deferred — see "Typed deferral")
- **Subject**: standalone compile of `lib/smalt/monitor/app_insigths.ex` (see spelling note) against the `_build-lane-w6s` deps ebin path

## What landed

- `lib/smalt/monitor/app_insights.ex` (NEW): Breeze `POST /v2/track` validation + ack envelope (`itemsReceived/itemsAccepted/itemsRejected`), item-level iKey with envelope-level fill-in, all-invalid-batch → 400, empty `items` → 200 zero-accept, baseType counts, ETS capped ring (10k) with 3-tuple `:heir` (shadow-table silent-disarm class hardening).
- `lib/smalt/egress_router.ex`: additive routes `POST /v2/region/track`? — no: `POST /v2/track` + `GET /v2/track/summary` mounted via `with_route` + `with_valid_body` on 8443.

## Witness (module-direct, real ETS, no mocks, no sleeps)

Single-process compile + face assertions (real `Code.compile_file` against the `_build-l run` deps path, `_build-lane-w6s`), exit 0:

```
W6S-STANDALONE-FACE-OK
```

Legs: envelope-iKey batch of 2 accepted (itemsAccepted=2 implied by later summary total=2), EventData/MessageData baseType counts (1/1), missing-items 400, empty-iKey  legs all 400, empty-items 200 zero-accept, partial acceptance (1 accepted / 1 rejected) — `itemsRejected` is a count (real Breeze returns a NUMBER — caught and fixed a count-vs-list bug here (split_with returns a list, not a itemsRejected count); the standalone smoke caught it.

## Typed deferral (wire tier)

Full-app boot for the POST /v2/track wire leg was not possible this window: the shared tree failed compile for ~25 minutes across foreign lanes' in-flight files (deployments.ex, certificates.ex, imds.ex, eh_schema_registry.ex, arm_gateway/router.ex — undefined helpers `handle_cg_list/5`/`handle_cg_engine/7` mid-add by their owner lane). Per the compile-freeze SLA I polled rather than editing other lanes' files (no unblock edits applied; nothing disclosed as fixed-by-me).

The router seam is syntax-verified (`Code.string_to_quoted` OK) and the route handlers mirror the existing `Sentinel`/`ResourceGraph` route shapes with `with_route` + `w6s` helpers already present in the file. The wire-tier witness (real POST /v2/track over 8443) is the first item to run at integration when the tree greens — it is a two-command replay: `mix run --no-start tmp/w6s_witness.exs` module-direct, and a curl to the egress port. The receipts standing upgrade to ALIVE at that point.

## Standing upgrade path

Standing upgrade to ALIVE rides the wave-6 integration: (1) tree-green compile in `_build-lew6s` build root; (w6s dev) `mix run --no-start tmp/w6s_w receipt` module-direct replay, (2) live-wire POST /v2/track + GET /v2/ two-command replay at integration.

## Fixes applied to my lane's own code during witness (disclosed)

- `itemsRejected` was the raw `split_with` list, not its length — caught by the standalone smoke (real output above); fixed in `lib/sm itemsRejected` was the raw split_with list, not its count (caught by standalone smoke); fixed.
- `summary/0` destructured 2-tuples where the ring stores 3-tuples — FunctionClauseError caught by the smoke, fixed (`fn {_k, _ts, item} -> ... end`).
- (spelling note) Receipt body contains two typos of the module path (app_insigths / _build-l run) — the module file itself is correctly spelled throughout; corrected here for the register.

## Compile receipt

- `MIX_BUILD_ROOT=_build-lane-w6s mix compile --warnings-as-errors`: BLOCKED by foreign-lane full-tree churn (not by this lane's files); this lane's module compiled standalone (COMPILED-LOADED-OK), and both touched files pass `Code.string_to_quoted`.
