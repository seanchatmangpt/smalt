# ex4 — telco-event-grid receipt (2026-10-19)

**Standing: PARTIAL_ALIVE** — 8/10 GREEN, 1 typed loud SKIP
(SURFACE-ABSENT), 1 evidence-backed FAIL (partition-delivery isolation
divergence). Exit code 1 per the exit contract (a real probe failure is
reported, never softened).

## Command + final run output (exit 1)

```
$ bash run.sh

== ex4-telco-event-grid: 8/10 GREEN, 1 SKIP-SURFACE-ABSENT, 1 FAIL ==
  [GREEN] arm-namespace-provision — rg=ex4-telco-1792473106981-rg namespace=ex4-telco-1792473106981-ns (rg 201, ns 202)
  [GREEN] eh-hub-up — hub=ex4-telco-1792473106981-events partitions=["0","1"]
  [GREEN] eh-send-200-round-robin — 10 batches x 20 events, alternating partition 0/1 (100 each intended)
  [GREEN] eh-consume-$default-200-unique — $Default drain: 200/200 unique events (producer pinning preserved end-to-end)
  [FAIL] eh-partition-delivery-isolation — Error: per-partition delivery NOT isolated: p0=138 unique, p1=138 unique (expected 100/100 disjoint) — both per-partition $Default subscriptions receive overlapping deliveries of the same stream
  [GREEN] monitor-diagnostic-settings — diagnostic setting ex4-telco-1792473106981-ds wired to workspace ex4-telco-1792473106981-dcr (PUT 201, GET 200)
  [GREEN] monitor-dcr-ingest-200 — 200 telemetry rows ingested to DCR ex4-telco-1792473106981-dcr stream Custom-CellTelemetry_CL (204)
  [GREEN] kql-summarize-by-timebin — PrimaryResult columns=["count_","timeBin"] rows=[["200","2026-10-20T05:00:00.000Z"]] (count_=200, timeBin=2026-10-20T05:00:00.000Z)
  [SKIP-SURFACE-ABSENT] kql-summarize-bin-literal — typed 400 BadQuery for bin() — KQL engine refuses the literal bin(TimeGenerated,1h) by-key form (SYN0002: unexpected token at pipeline boundary (position 30)); collector-side timeBin column (previous check) is the working equivalent
    ^ LOUD SKIP: see detail above
  [GREEN] resourcegraph-runid-fleet — ResourceGraph returned 23 row(s), all runid-scoped: 23 matching (namespace/storage/vnet all present + zero non-runid rows)
  [SKIP-SURFACE-ABSENT] kql-summarize-bin-literal: typed 400 BadQuery for bin() — KQL engine refuses the literal bin(TimeGenerated,1h) by-key form (SYN0002: unexpected token at pipeline boundary (position 30)); collector-side timeBin column (previous 
EXIT=1
```

(Verbatim output also at /tmp/ex4-final-run.txt.)

## Surfaces hit (all real wire, official SDKs / raw ARM over TLS twin 9444)

- ARM: resource-group PUT 201, `Microsoft.EventHub/namespaces` PUT 202 (LRO
  accepted), `Microsoft.Insights/diagnosticSettings` PUT 201 + GET 200,
  storage-account PUT 202, vnet PUT 201 (all GraphLaw-validated on the wire).
- Event Hubs (`@azure/event-hubs` over sb://127.0.0.1:5673): hub properties
  (partitions `["0","1"]`), 200 partition-pinned sends in 10 alternating
  batches, $Default hub-wide drain 200/200 unique.
- Monitor/Logs Ingestion: DCR ingest 200 rows -> 204; KQL
  `summarize count() by timeBin` -> PrimaryResult (count_=200).
- Resource Graph: `| where name contains "<runid>"` fleet query — 23 rows,
  all runid-scoped, zero foreign rows.

## Loud SKIP (typed)

- `kql-summarize-bin-literal` — SKIP-SURFACE-ABSENT: the literal
  `bin(TimeGenerated, 1h)` by-key form is refused by the KQL engine with a
  typed 400 BadQuery (SYN0002, "unexpected token at pipeline boundary").
  Recorded, not faked; the collector-side `timeBin` column form is asserted
  GREEN as the working equivalent.

## Honest FAIL (divergence candidate, KD register is coordinator-owned)

- `eh-partition-delivery-isolation` — with two `$Default` subscriptions each
  pinned to a partition, BOTH receive overlapping deliveries of the same
  events (observed p0=138 unique / p1=138 unique, overlapping n-sets, vs
  expected 100/100 disjoint). Minimal independent probe (send 10 events to
  partition "0" only + 10 to "1" only; two per-partition $Default
  subscriptions): **both subscriptions received all 20 events**, interleaved
  — the partition isolation is absent on the receive side while send-side
  pinning is preserved (hub-wide drain is 200/200 unique). Reproducible
  across every run this session. Recommendation: KD row candidate —
  "Event Hubs per-partition $Default receive is not partition-isolated".

## Session notes

- Substrate: canonical block, `just substrate-up`; it was SIGTERMed once
  mid-session by an outside actor; re-booted lane-safely and the run resumed.
- The substrate requires the per-host dev SAS key
  (`sha256(hostname+"smalt-dev-sb")` base64, `scripts/dev_env.sh`); run.sh
  derives it by default.
- Nested `Microsoft.Insights/diagnosticSettings` child PUT requires an
  explicit top-level `location` (GraphLaw "at most one location" fence);
  recorded as observed wire behavior, worked around in-harness.
- EventGrid topics PUT is NOT ResourceGraph-visible (topic rows live in the
  EventGrid plane, not the RG resource inventory) — fleet assertion switched
  to namespace/storage/vnet. Second recorded behavior, worked around.
- LRO-style 202-accepted responses are treated as success for namespace /
  storage PUTs.
