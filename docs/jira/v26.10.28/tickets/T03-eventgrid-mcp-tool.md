# T-03 — Event Grid: MCP tool surface

- status: CLOSED (2026-10-28): tools live (33 total) - receipts: commit 474518c + wire calls verified
- window: v26.10.28 · maps-to: Topaz v1.11 "Event Grid — … MCP tool" (the control-plane half is already ahead) · verdict-at-open: **PARTIAL**
- size: **S** · depends-on: — · parity-leg: MCP probe (9545)

## current state (evidence)

smalt's Event Grid control plane is ahead of Topaz's "initial" milestone:
topics + systemTopics + eventSubscriptions ARM routes
(`lib/smalt/arm_gateway/router.ex`), egress publish + webhook receiver
(`Smalt.EventGridWebhookPlug`), and the ResourceWriteSuccess→Service Bus
bridge (`lib/smalt/egress_router.ex`, `@sb_bridge_queue`). The MCP
descriptor (`lib/smalt/mcp/generated/mcp_descriptor.ex`) carries
`appconfig.snapshots.*` but no eventgrid tool — that is the named gap.

## scope

Read-only Event Grid tools in the descriptor + router registration, e.g.:

- `eventgrid.topics.list` / `eventgrid.topics.get`
- `eventgrid.subscriptions.list` (per topic)
- `eventgrid.events.recent` (recent published events, bounded window)

Every tool carries `readOnlyHint`; any mutating call answers
`ACTUATION_REFUSED` exactly like the existing tools
(`lib/smalt/mcp/router.ex` law).

## non-goals

- Publishing events through MCP (read-only law, no exceptions).
- New server state — `events.recent` reads the existing event/OCEL records.

## Definition of Done — the Azure developer's view

You connect an MCP client (Claude, VS Code, or a plain MCP inspector) to
`http://127.0.0.1:9545` and ask it "what Event Grid topics do I have and
what fired recently?" — the client lists the new eventgrid tools alongside
the existing ones, calling them returns your topics and subscriptions with
the same names and ids you see via the ARM SDK, and the recent-events tool
shows the events your app published moments earlier. Asking the assistant
to create or delete a topic through MCP gets a typed refusal, not a silent
no-op.

## receipts required

MCP probe receipt: tool list + one call per tool + an ACTUATION_REFUSED
mutation attempt.
