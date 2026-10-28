# v26.10.28 — Topaz roadmap → smalt parity map

Window scope: map EVERY item of the vendored Topaz roadmap (v1.11–v1.14,
captured from topaz.thecloudtheory.com/roadmap on 2026-10-28; vendored pin
`vendors/topaz` @ `7832dff901c1`, gitignored embedded repo) onto smalt's
current surface, with file:line evidence per item. This is the planning
companion to the window's landed parity work: commit `8a6ce57` (blob/queue
Azure-parity fixes; `parity/reports/mvsqkf7q-36121c/report.md` is the
receipt) and `parity/COVERAGE_VS_TOPAZ.md` (service-level comparison).

Verdict vocabulary (closed enum, same discipline as the SDK coverage
enum in `verification/README.md`):

| verdict | meaning |
|---|---|
| **COVERED** | smalt mounts the surface today, with evidence |
| **PARTIAL** | smalt mounts an adjacent/subset surface; the roadmap item names a gap inside it |
| **GAP** | smalt has nothing on this surface |
| **OUT-OF-SCOPE** | the item is against smalt's stated design law (no Docker/hosts/native deps) |

Roadmap items are quoted from the captured page; the smalt column is
source-verified on this date. Where a parity-harness leg exists or is
cheap, it is named — the harness (`parity/run.mjs`) is the acceptance
instrument for any CLOSE work coming out of this map.

## v1.11

| Topaz item | smalt today | verdict | evidence / notes |
|---|---|---|---|
| Container Registry — ACR Tasks multi-step execution (FileTaskRunRequest & EncodedTaskRunRequest) | no `Microsoft.ContainerRegistry` provider anywhere in `lib/`; the only ACR trace is the metadata DNS suffix `"containerRegistry" => "registry.smalt.local"` (`lib/smalt/arm_gateway/router.ex:3065`) | **GAP** | whole ACR plane (incl. the existing v1.10 ACR Topaz already ships — see `parity/COVERAGE_VS_TOPAZ.md` ACR row) is absent; Tasks multi-step extends a plane smalt does not mount |
| Resource pre-seeding — `topaz seed` imports existing Azure resources into local state | no import CLI; nearest surfaces: `smalt-cli/` (zero-actuation Python companion) and the semantic projection (`lib/smalt/semantic/resource.ex`, `lib/smalt/projection/`) which can RENDER state but not ingest it | **GAP** | a smalt-side `seed` would be an actuation-class feature — conflicts with the AU-10 zero-actuation gate on `smalt-cli`; any CLOSE must scope it to the Elixir substrate CLI only |
| Event Grid — initial control plane, event subscriptions, publishing, system topics, MCP tool | ARM routes exist for topics + systemTopics + eventSubscriptions (PUT/GET/DELETE/LIST, `lib/smalt/arm_gateway/router.ex` — 37/45 documented ops in Topaz's own table vs smalt's mounted set); egress Event Grid publish + webhook receiver (`Smalt.EventGridWebhookPlug`); ResourceWriteSuccess→SB bridge (`lib/smalt/egress_router.ex` `@sb_bridge_queue "resourcewritesuccess"`); NO eventgrid MCP tool (descriptor `lib/smalt/mcp/generated/mcp_descriptor.ex` carries `appconfig.snapshots.*` but no eventgrid tool) | **PARTIAL** | smalt is AHEAD of Topaz's "initial" milestone on the control plane (already shipped); the two named CLOSE items are the eventgrid MCP tool and any op-level diffs vs Topaz 37/45 |
| App Configuration — snapshots, Key Vault references, EventGrid change notifications | snapshots SHIPPED: `lib/smalt/data_plane/appconfig_snapshots.ex` + MCP tools `appconfig.snapshots.kv` / `appconfig.snapshots.list` (descriptor evidence above); KV references (config values resolving to Key Vault secrets): absent; EG change notifications on kv writes: the SB bridge fires on ResourceWriteSuccess (ARM writes) — kv-plane change events not wired | **PARTIAL** | one of three sub-items already ahead (snapshots, with MCP exposure Topaz does not list); CLOSE = KV-ref resolution at read time + kv-write event emission |
| App Insights / Log Analytics — extended KQL: join, mv-expand, bin(), ago(), cross-workspace | `lib/smalt/data_plane/kql.ex` parses/evals a scalar-dialect KQL incl. `ago(<dur>)`, `now()`, `datetime()` (source-verified); no join/mv-expand/bin()/cross-workspace operators; Sentinel surface rides it (`sentinel.ex`) | **PARTIAL** | operator-gap list is exactly {join, mv-expand, bin, cross-workspace}; smalt's KQL receipts live in the Sentinel/LogAnalytics courts |
| Redis Cache — RESP2 data plane, TLS listener, connection strings | no Redis/RESP surface in `lib/smalt/data_plane/` (16 modules, none Redis) | **GAP** | RESP2 is a binary protocol — new listener class, closer to the AMQP tier than to the HTTP data planes |

## v1.12

| Topaz item | smalt today | verdict | evidence / notes |
|---|---|---|---|
| API Management — policy execution (rate-limit, set-header/body, validate-jwt, backend forwarding) | no APIM resource/service; but the four named policies exist as SUBSTRATE-WIDE primitives: fixed-window 429 + Retry-After (`:arm_rate_limit`), Bearer/STS validation on every plane (`lib/smalt/auth/bearer.ex`; enforce mode), CORS/header policy on egress (`:egress_cors_origins`) | **PARTIAL** (adjacent) | the primitives are ahead (they apply to ALL planes, not one APIM resource); the resource-model (policy XML on an APIM entity + backend pools) is the actual gap |
| Service Bus — DLQ, scheduled messages, message deferral | no native SB dead-letter subqueue — `lib/smalt/sb_rules.ex:104` states "any filter matches -> admit; otherwise skip (never DLQ here)"; a DLQ exists ONLY in the EventGrid→SB ingestion bridge (dead-letters to a blob container, `lib/smalt/messaging/event_grid.ex`); no scheduled-delivery / deferral (SequenceNumber-based) surface in the AMQP broker | **PARTIAL** | CLOSE = `%DeadLetterQueue` subqueues per subscription (AMQP settle + rules), scheduled enqueue (`x-ms-scheduled-enqueue-time`), deferral via sequence number |
| Event Hub — consumer group epoch tracking, checkpoint store simulation, partition cursor persistence | checkpoints with compare-and-swap + leases + reconcile SHIPPED (`lib/smalt/messaging/event_hubs.ex` — checkpoint CAS, `reserve_processing/4`, `reconcile/3`; receipted in `test/internal/event_hubs_consumer_groups_test.exs` and `test/internal/eh_geo_dr_test.exs`); Store-backed state persists via the DETS mirror; epoch tracking (owner-level enforcement on consumer groups) absent | **PARTIAL** | smalt is AHEAD on the store mechanics Topaz is still "simulating"; epoch enforcement is the single named CLOSE |

## v1.13

| Topaz item | smalt today | verdict | evidence / notes |
|---|---|---|---|
| Container Instances — Docker-backed execution, log streaming, local ACR integration | nothing; and Docker-backed execution is against smalt's design law — the README's standing contract is "no cloud connection, no host configuration for the native tier"; this box additionally has no Docker | **OUT-OF-SCOPE** (execution) / **GAP** (control plane) | if anything: the ARM control-plane resource (PUT/GET list of container groups, status model) is in-scope and portable; execution never is |
| Azure Functions — Function App resource type, admin API, host.json | nothing in `lib/` (no `Microsoft.Web/sites`) | **GAP** | same split as CI: resource-type + admin API could ride the ARM registry pattern; host.json semantics are host-runtime territory |
| Chaos Engineering — AMQP link detach injection, credit starvation, session timeout injection | chaos is a SHIPPED smalt tier, different injection points: SIGKILL storms (receipt `docs/jira/v26.10.18/receipts/azb-14-sigkill-storm.md`), Store-kill mid-run (`test/internal/dets_mirror_recovery_test.exs`), throttle profiles (`:cosmos_ru_limit`, `:arm_rate_limit` via boot-eval); no AMQP link/credit/session-level injectors | **PARTIAL** | the roadmap names protocol-level injects inside the broker; smalt's law-abiding equivalents would be broker-internal fault flags (detach-on-N, credit-starve, session-timeout) behind typed config keys |

## v1.14

| Topaz item | smalt today | verdict | evidence / notes |
|---|---|---|---|
| OpenTofu — verified compatibility, dedicated suite, coverage docs | azurerm plan-smoke shipped (`just tf-plan-smoke`, terraform fixtures against the substrate); no OpenTofu-branded suite | **PARTIAL** | OpenTofu speaks the azurerm provider wire — the plan-smoke transfers mechanically; CLOSE = run the fixture suite under the `tofu` binary + a receipt |
| Azure Service Health — Resource Health availability statuses, Service Health events, chaos-injectable incidents | no `Microsoft.ResourceHealth` provider; nearest is the substrate's own adaptive health probes (egress readiness/liveness, envelope Phase 4) — internal, not an ARM surface | **GAP** | statuses could derive from the plane registry (`lib/smalt/planes.ex`) + chaos flags; "chaos-injectable" couples to the v1.13 injector lane above |
| IaC state export — `export --format bicep/terraform` | no export CLI; the semantic projection (`lib/smalt/semantic/resource.ex` + `lib/smalt/projection/`) already normalizes mounted resources — the natural substrate for an exporter | **GAP** (foundation exists) | export is read-only (no actuation-gate conflict); bicep/JSON emit from the projection is the cheap first leg |
| Service Bus — chained DLQ forwarding (A→B→C, configurable hops) | no DLQ to chain from (see v1.12 SB row) — strictly downstream of that CLOSE | **GAP** (blocked) | sequence after native DLQ lands |

## summary

| verdict | count | items |
|---|---|---|
| COVERED | 0 | (nothing on Topaz's FUTURE list is fully already-in-smalt — the already-covered overlaps live in the v1.10 service table, `parity/COVERAGE_VS_TOPAZ.md`) |
| PARTIAL | 8 | EventGrid(+MCP tool gap), AppConfig(KV-refs, EG notify), KQL(4 operators), APIM(resource model), SB(DLQ/scheduled/deferral), EH(epoch), Chaos(AMQP injectors), OpenTofu(branded suite) |
| GAP | 7 | ACR, seed, Redis, ServiceHealth, export, SB-chained-DLQ, Functions |
| OUT-OF-SCOPE | 1 | CI Docker execution (two more items split GAP/OUT on their control planes) |

## recommended CLOSE order for smalt (cheap→structural, parity-first)

1. **EH consumer-group epoch** — small, rides shipped checkpoint/lease machinery; harness-leg: eh suite epoch races.
2. **OpenTofu plan-smoke under `tofu`** — mechanical transfer of an existing gate.
3. **eventgrid MCP tool** (read-only, matches `appconfig.snapshots.*` precedent in the descriptor).
4. **KQL operators (bin → ago exists → join → mv-expand → cross-workspace)** — each operator is a court-able parser/eval increment in `kql.ex`.
5. **AppConfig KV-references + kv-write events** — read-time resolution through the mounted KV plane + the existing SB bridge.
6. **SB native DLQ → scheduled → deferral → (v1.14) chained forwarding** — one lane, four receipts, unlocks two roadmap rows.
7. **IaC export from the semantic projection** (bicep JSON first, HCL stub after).
8. Structural/new-listener class, separately windowed: Redis RESP2, ACR (control plane first), ServiceHealth, Functions/CI control-plane-only rows, AMQP chaos injectors, APIM policy resource model, `seed` (substrate CLI only, actuation-gate caveat).

Every CLOSE that has a wire-visible surface lands with a parity-harness leg
or an SDK probe — a CLOSE without a receipt is not a CLOSE (the
`verification/README.md` surface-enum law, applied to this map).
