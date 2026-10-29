# ex4 — Telco Event-Ingestion Grid

A Fortune-500 telco archetype on the smalt substrate: a national carrier's
cell-site telemetry grid. 200 events/day per region flow from cell sites
through Event Hubs (pinned round-robin across the fixed partitions `["0","1"]`),
land in a Log Analytics workspace through the Monitor surface (ARM
`Microsoft.Insights/diagnosticSettings` + Logs Ingestion DCR), are interrogated
with KQL `summarize`, and the whole fleet is discovered by a cross-resource
Resource Graph query scoped to the run's `runid` tag.

## Surfaces exercised

| Surface | Wire | What is proven |
|---|---|---|
| ARM control plane | TLS twin `https://localhost:9444` | RG + `Microsoft.EventHub/namespaces` PUT (201/202), GraphLaw-validated |
| Event Hubs | `sb://127.0.0.1:5673` via `@azure/event-hubs` | hub properties (partitions `["0","1"]`), 200 partition-pinned events in 10 alternating batches, $Default drain 200/200 unique |
| Monitor (ARM) | TLS twin | `Microsoft.Insights/diagnosticSettings` PUT 201 + GET 200 on the namespace |
| Monitor (Logs Ingestion) | TLS twin `/dataCollectionRules/...` | 200 telemetry rows into `Custom-CellTelemetry_CL` (204) |
| KQL | TLS twin `/v1/workspaces/.../query` | `summarize count() by <col>` PrimaryResult shape (columns `count_`+`timeBin`, one group, `count_=200`) |
| Resource Graph | TLS twin `/providers/Microsoft.ResourceGraph/resources` | runid-scoped fleet query: namespace + storage account + vnet, zero foreign rows |

## Run

```bash
just substrate-up        # if down
bash examples/telco-event-grid/run.sh
```

Exit contract: 0 pass / 1 probe failure / 2 substrate down / 3 loud skip.

## Known findings (as of 2026-10-19)

- **`eh-partition-delivery-isolation` FAIL** — per-partition `$Default`
  subscriptions are not partition-isolated: both partition subscriptions
  receive overlapping deliveries of the same event stream (probe receipt in
  `receipt.md`). The send-side pinning is preserved end-to-end (200/200 unique
  on the hub-wide $Default drain). Divergence candidate for the KD register —
  the lane records the observed wire behavior verbatim, never a fake pass.
- **`kql-summarize-bin-literal` SKIP-SURFACE-ABSENT** — the KQL engine refuses
  the literal `bin(TimeGenerated, 1h)` by-key form with a typed 400 BadQuery
  (`SYN0002`); the collector-side `timeBin` column is the working equivalent
  and is asserted green.

## Notes

- Default SAS key is the per-host dev key (`sha256(hostname+"smalt-dev-sb")`
  base64), matching `scripts/dev_env.sh`; override with `SMALT_SB_SHARED_KEY`.
- Unique names `ex4-telco-<ts>-*`; env retarget via `SMALT_EX4_*` variables.
- No smalt `lib/` imports, no mocks, no fixed sleeps (harness `boundedPoll`
  and deadline-raced drains only).
