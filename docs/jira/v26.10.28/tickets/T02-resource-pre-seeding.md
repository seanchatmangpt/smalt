# T-02 — Resource pre-seeding: import existing Azure resources into local state

- status: CODE-COMPLETE (2026-10-29): r10, awaiting integration run
- window: v26.10.28 · maps-to: Topaz v1.11 "Resource pre-seeding — `topaz seed`" · verdict-at-open: **GAP**
- size: **M** · depends-on: — · parity-leg: read-back probes (ARM GET parity)

## current state (evidence)

No import path exists. Nearest surfaces: `smalt-cli/` (zero-actuation Python
companion, AU-10 gate — it must stay actuation-free) and the semantic
projection (`lib/smalt/semantic/resource.ex`, `lib/smalt/projection/`) which
renders mounted state but cannot ingest it. The map row notes the actuation
caveat: seeding is state hydration, not cloud actuation, so it belongs to
the Elixir substrate tooling, never `smalt-cli`.

## scope

1. A substrate-side `seed` runner (mix task or `scripts/` entry) that reads
   an exported resource corpus (JSON — resource ids + bodies, produced by
   `az resource list` + `az resource show`, or `az bicep export` output).
2. Ingestion writes ARM registry rows through the same materialization the
   PUT paths use (defaults application included), so seeded resources GET
   byte-identically to created ones.
3. A dry-run mode printing the would-be seeded ids; and idempotent re-runs.

## non-goals

- Live Azure connectivity inside the substrate (the export happens on the
  developer's machine with their own `az` session; smalt never phones out).
- Any write-back/export-to-cloud direction.

## Definition of Done — the Azure developer's view

You have a dev subscription with a handful of resources (RGs, a storage
account, a Key Vault, a Service Bus namespace). You export them once from
real Azure (`az resource list --output json` + bodies), run the seed
command against your local substrate, and then — with the SDK or `az`
pointed at smalt — `GET` each of those exact resource ids and receive the
same `id`/`name`/`location`/`properties` you see in the real cloud, without
ever having PUT them locally. Your application's `AzureEnvironment`/client
config works unchanged against the seeded world, and a seeded storage
account's `listKeys` returns usable local keys.

## receipts required

Seed-from-export fixture → GET-parity receipt (seeded vs hand-PUT responses
diffed); idempotency receipt (double seed = no-op).
