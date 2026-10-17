# TS SDK Results: Azure Resource Graph surface (`@azure/resource-graph` class, raw REST) vs smalt

Subject: `/Users/sac/smalt` v26.10.16 working tree, lane 326 (KD-38 probe-authoring), 2026-10-16.
Probe source: `/Users/sac/smalt/test/sdk-full/resourcegraph.probe.mjs` (added by this lane).
Run log: `/tmp/rg-lane326-probe.log`.

## Environment

- node v26.x; `@azure/resource-graph` is NOT vendored in `test/sdk-full/node_modules`,
  so the probe drives raw REST in the probe harness — the exact envelope the
  real SDK emits (`POST /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`).
- Substrate: lane-private boot under `MIX_BUILD_ROOT=_build-lane326`, ports
  ARM 39308 / TLS twin 39309 / egress 39310 (AMQP 39311, EH 39312), auth
  `:enforce`, CA-signed dev TLS material via SMALT_TLS_CERTFILE/KEYFILE.
  TLS twin served the CA-signed leaf — no `NODE_TLS_REJECT_UNAUTHORIZED` caveat
  from the v26.10.14 self-signed-leaf finding needed beyond the env var itself.
- Route reached over the TLS twin: `/providers/` prefix dispatches to
  EgressRouter (lib/smalt/application.ex TlsTwinDispatch), so the Resource
  Graph surface is wire-visible on 9444-class ports.

## Verdict: 4 PASS / 1 DIVERGENCE

| # | Probe | Verdict | Evidence |
|---|---|---|---|
| 1 | seed: ARM generic PUT NSG | PASS | 201; id round-trips into the resource inventory |
| 2 | rg.query happy path (subscriptions=[sub], `project name`) | PASS | 200; `count=1 totalRecords=1`, envelope carries count/data/totalRecords; seeded NSG present in data |
| 3 | wrong api-version 2019-04-01 | PASS | typed `400 InvalidApiVersion` (never 500) |
| 4 | subscriptions as string | PASS | typed `400 InvalidParameter` (never 500, never silent all-resources) |
| 5 | unparseable KQL (`totally not kql ~~~`) | **DIVERGENCE** | wire `200` with unfiltered full inventory (`count=1`) instead of typed `400 BadQuery`. Real Azure: 400 BadQueryError-class error body |

Run receipt (from `/tmp/rg-lane326-probe.log`, negative verdict tokens normalized to DIVERGENCE):

```
SUMMARY: 4/5 probes passed
  PASS  seed :: seeded 201
  PASS  rg.query happy path :: count=1 totalRecords=1 seeded NSG present
  PASS  rg.wrong api-version :: 400 InvalidApiVersion (typed)
  PASS  rg.subscriptions as string :: 400 InvalidParameter (typed, never 500)
  DIVERGENCE  rg.bad KQL :: expected 400, got 200: {"count":1,"data":[{...full resource...}]}
```

## Findings

1. **D1 — garbage KQL accepted, full inventory leaked (DIVERGENCE row for
   KD-38)**: `POST /providers/Microsoft.ResourceGraph/resources` with
   `query: "totally not kql ~~~"` returns 200 with the unfiltered resource
   list. `Smalt.DataPlane.ResourceGraph.query/3` (lib/smalt/data_plane/resource_graph.ex)
   only throws `{:bad_query, msg}` from the KQL parser on recognizable-but-
   invalid syntax; a query the parser cannot classify at all falls through to
   a match-all. Real Azure: 400 with `BadRequestFormat`/BadQueryError body.
   A typed 400 naming the gap is a complete cell (80/20 scope trim); this
   receipt is the KD-38 close-condition evidence.
2. Happy-path + typed refusals are implemented behavior: envelope shape
   (count/data/totalRecords), api-version fence, and the subscriptions-shape
   fence (lane 19 item 3 fence re-verified over TLS) all hold on the wire.
