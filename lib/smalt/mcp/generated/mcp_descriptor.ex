# Generated MCP capability descriptor for the Smalt read-only surface.
# Generated from lib/smalt/mcp/gen/smalt_mcp_surface.ttl via ggen_igniter.sync
# using the elixir-mcp-a2a-pack queries (mcp_capabilities.rq) and this EEx
# adaptation of the pack's mcp_descriptor.ex.tmpl. DO NOT hand-edit the
# generated output; edit the TTL and re-run the sync command in the TTL header.
defmodule Smalt.Mcp.Descriptor do
  @moduledoc """
  Per-capability metadata for Smalt's read-only surface, generated
  from one ema:CapabilitySurface (elixir-mcp-a2a-pack descriptor shape,
  adapted to Smalt's capability list). A caller can check
  `requires_authority?/1` (fail-closed on unregistered ids) or
  `read_only_surface?/0` BEFORE invoking a tool, rather
  than discovering refusal at runtime.
  """

  @capabilities %{
    "appconfig.snapshots.kv" => %{
      name: "App Configuration snapshot KV view",
      description:
        "Frozen KV view of one App Configuration snapshot by name (records as stored at creation; archived snapshots refuse SnapshotArchived).",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "appconfig.snapshots.list" => %{
      name: "App Configuration snapshots list",
      description:
        "App Configuration snapshot settings (name, filters, status, itemCount, etag) — frozen KV bodies are never projected.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "arm.get" => %{
      name: "ARM resource get",
      description: "Read one ARM resource record from the substrate store by resource-id parts.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "atlas.lineage.get" => %{
      name: "Atlas lineage get",
      description:
        "Purview Atlas v2 lineage slice for one guid (BFS over the lineage edge table; direction input/output/both, bounded depth).",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "blob.list" => %{
      name: "Blob listing",
      description: "Content-free metadata listing of blobs in one storage container.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "certificates.get" => %{
      name: "Key Vault certificate get",
      description:
        "Certificate attributes for one certificate (id, name, attributes) — never key material, private key, or the DER body.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "cluster.status" => %{
      name: "Cluster status",
      description:
        "Cluster poller status: enabled, joined nodes, dns name/port, exhausted addresses.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "cosmos.changefeed.peek" => %{
      name: "Cosmos change feed peek",
      description:
        "Pending change-feed rows for a container (docs newer than the persisted cursor), counted WITHOUT advancing the cursor — read-only unlike the wire change feed.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "cosmos.query" => %{
      name: "Cosmos document query",
      description:
        "Read-only document query over a Cosmos container (cross-partition or per partition key).",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "cosmos.stats" => %{
      name: "Cosmos stats",
      description:
        "Content-free per-container document counts (databases, collections, documents) from the cosmos meta and doc tables.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "cosmos.uniquekeys.get" => %{
      name: "Cosmos unique key policy get",
      description:
        "The uniqueKeyPolicy recorded at container creation for one Cosmos container (uniqueKeys paths; empty list when none was declared).",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "doctor.summary" => %{
      name: "Doctor summary",
      description:
        "Substrate health summary: supervisor children, store and cosmos readiness, listener ports.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "eg.dlq.list" => %{
      name: "Event Grid dead-letter listing",
      description:
        "Content-free metadata of dead-lettered Event Grid event blobs per subscriber container.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "eh.consumergroups.list" => %{
      name: "Event Hubs consumer groups list",
      description:
        "Consumer group records for one Event Hub ($default always present), from the Event Hubs server store.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "health.readiness" => %{
      name: "Health readiness",
      description:
        "Structural readiness verdict with scheduler/store/memory/cluster checks (degrades on structure, never load).",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "kv.certificates.list" => %{
      name: "Key Vault certificates list",
      description:
        "Certificate list envelope (id, name, attributes) from the certificates plane — never key or private-key material.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "kv.deletedkeys.list" => %{
      name: "Key Vault deleted keys list",
      description:
        "Soft-deleted vault key bundles (recoveryId, deletedDate, scheduledPurgeDate) from the deleted-keys table.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "kv.deletedsecrets.list" => %{
      name: "Key Vault deleted secrets list",
      description:
        "Soft-deleted vault secret bundles (recoveryId, deletedDate, scheduledPurgeDate) from the deleted-secrets table — never secret value material.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "kv.get" => %{
      name: "Key Vault key get",
      description:
        "Public record of one vault key (never key material) from the vault key table.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "lro.operations.list" => %{
      name: "Long-running operations list",
      description:
        "In-flight and terminal LRO operation records from the operations store, optional subscription filter.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "policy.exemptions.list" => %{
      name: "Policy exemptions list",
      description:
        "Policy exemptions under one scope prefix (subscription or resource-group placement).",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "policy.locks.list" => %{
      name: "Policy locks list",
      description:
        "Management locks (Microsoft.Authorization/locks) under one scope prefix, level and notes projected, never lock-token material.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "policy.remediations.list" => %{
      name: "Policy remediations list",
      description:
        "Typed diagnostic remediation table (code to remediation command, closed severity vocabulary) from the substrate remediation registry.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "policy.setdefinitions.list" => %{
      name: "Policy set definitions list",
      description:
        "Policy set definitions (Microsoft.Authorization/policySetDefinitions) under one subscription, id-sorted.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "sb.peek" => %{
      name: "Service Bus peek",
      description: "Peek messages from a Service Bus queue without locking or completing them.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "sb.rules.list" => %{
      name: "Service Bus rules list",
      description:
        "Subscription rules (Microsoft.ServiceBus/namespaces/topics/subscriptions/rules) for one topic/subscription pair, optional namespace filter — filter and action definitions only.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "sb.topics.list" => %{
      name: "Service Bus topics list",
      description:
        "Service Bus topic resources (Microsoft.ServiceBus/namespaces/topics) from the substrate resource store, optional namespace filter.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "sb.topics.subscriptions" => %{
      name: "Service Bus topic subscriptions",
      description:
        "Subscription resources (Microsoft.ServiceBus/namespaces/topics/subscriptions) under one Service Bus topic.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "substrate.capabilities" => %{
      name: "Substrate capabilities",
      description:
        "Registry-derived admitted resource types, api-versions, and SHACL shape bindings.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "substrate.status" => %{
      name: "Substrate status",
      description:
        "Liveness summary of the substrate: store, supervisor, listeners, ports, version.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    # v26.10.28 T-03: Event Grid read tools (source of record:
    # lib/smalt/mcp/gen/smalt_mcp_surface.ttl, capabilityOrder 31-33; the
    # in-tree generator is absent, so this generated file is kept in the
    # shape the template produces — regenerate on top of the TTL when the
    # elixir-mcp-a2a-pack is available).
    "eventgrid.topics.list" => %{
      name: "Event Grid topics list",
      description:
        "Event Grid topics and system topics registered in the substrate ARM store (id, name, properties) - bounded to 100 rows.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "eventgrid.subscriptions.list" => %{
      name: "Event Grid event subscriptions list",
      description:
        "Event Grid event subscriptions (topic-scoped when a topic is named) registered in the substrate ARM store - bounded to 100 rows.",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    },
    "eventgrid.events.recent" => %{
      name: "Event Grid recent events",
      description:
        "The most recent published Event Grid events from the substrate event store (defensive projection, bounded to 25).",
      observation_scope: :read_only,
      mutation_scope: :none,
      requires_authority: false,
      reversible: true,
      consequence: :observe,
      receipt_semantics: :logged
    }
  }

  @doc "Full descriptor map, e.g. for an MCP `tools/list` response."
  @spec capabilities() :: %{String.t() => map()}
  def capabilities, do: @capabilities

  @doc "Descriptor for one capability id, or :error if unregistered."
  @spec describe(String.t()) :: {:ok, map()} | :error
  def describe(capability_id), do: Map.fetch(@capabilities, capability_id)

  @doc "True when every registered capability is read-only (mutation_scope :none)."
  @spec read_only_surface?() :: boolean()
  def read_only_surface? do
    @capabilities
    |> Map.values()
    |> Enum.all?(&(&1.mutation_scope == :none and not &1.requires_authority))
  end

  @doc """
  Fail-closed authority check per capability (elixir-mcp-a2a-pack convention):
  an UNREGISTERED tool id is treated as authority-requiring, never callable.
  """
  @spec requires_authority?(String.t()) :: boolean()
  def requires_authority?(capability_id) do
    case describe(capability_id) do
      {:ok, %{requires_authority: r}} -> r
      :error -> true
    end
  end
end
