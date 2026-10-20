# Cascade teardown dispatch — GENERATED from smalt-substrate-pack
# ontology via ggen_igniter.sync. DO NOT EDIT — regenerate with
# `mix smalt.gen`.
#
# Source of truth: ../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl
#   (smalt:CascadeEdge individuals; queries/cascade_edges.rq).
# One row per capture-then-sweep edge in the live teardown paths (E2
# census: RG/storageAccount/vault DELETE in arm_gateway/router.ex,
# Cosmos.drop_db/drop_container, Enclave.State.destroy). This module is
# the PROJECTED DECLARATION + DISPATCH table, not the drops: the
# owner-module drop functions stay hand-written (residue doctrine).
# sweep_dispatch/2 returns the sweep ACTIONS for a (table, key) pair —
# prefix sweeps and tuple deletes execute through Smalt.Store; owner
# delegation returns a {:delegate, ...} action the caller resolves.
#
# Replay identity is fenced by test/cascade_replay_identity_test.exs;
# coverage of every cascade-strategy StoreTable is fenced by
# verify/cascade-coverage.unbound.rq (run in the same test).
defmodule Smalt.CascadeEdges do
  @moduledoc """
  Machine-projected cascade teardown dispatch table (W2a).

  Every row is one capture-then-sweep edge: a DELETE of
  `parent_resource` sweeps `table` rows extracted from the swept ARM
  keys via `key_extraction` (with `capture_regex` for regex-capture
  edges). The dispatch is declarative: `sweep_dispatch/2` projects each
  edge to an action; executing owner-module drops stays hand-written.
  """

  # Canonical ordering: rows sorted by (parent_resource, table) at
  # render time so the artifact is independent of SPARQL engine row
  # order. Replay identity fenced by test/cascade_replay_identity_test.exs.
  

  @cascade_edges [
    %{
      parent_resource: "Microsoft.DocumentDb/sqlContainers",
      table: :smalt_cosmos_pk_meta,
      key_extraction: :tuple_exact,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.Cosmos"
    },

    %{
      parent_resource: "Microsoft.DocumentDb/sqlDatabases",
      table: :smalt_cosmos_pk_meta,
      key_extraction: :tuple_exact,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.Cosmos"
    },

    %{
      parent_resource: "Microsoft.KeyVault/vaults",
      table: :smalt_metrics,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.Metrics"
    },

    %{
      parent_resource: "Microsoft.KeyVault/vaults",
      table: :smalt_resources,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.ArmGateway.Router"
    },

    %{
      parent_resource: "Microsoft.KeyVault/vaults",
      table: :smalt_vault_secrets,
      key_extraction: :regex_capture,
      capture_regex: ~r/vaults\/[^\/]+\/secrets\/([^\/]+)/,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.VaultData"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_blob_blocks,
      key_extraction: :regex_capture,
      capture_regex: ~r/storageaccounts\/([^\/]+)/,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_blob_containers,
      key_extraction: :regex_capture,
      capture_regex: ~r/storageaccounts\/([^\/]+)/,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_blob_policy,
      key_extraction: :regex_capture,
      capture_regex: ~r/storageaccounts\/([^\/]+)/,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_blob_snapshots,
      key_extraction: :regex_capture,
      capture_regex: ~r/storageaccounts\/([^\/]+)/,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_blobs,
      key_extraction: :regex_capture,
      capture_regex: ~r/storageaccounts\/([^\/]+)/,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_cosmos_pk_meta,
      key_extraction: :regex_capture,
      capture_regex: ~r/sqlDatabases\/([^\/]+)\/sqlContainers\/([^\/]+)|sqlDatabases\/([^\/]+)/,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.Cosmos"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_metrics,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.Metrics"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_resource_groups,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.ArmGateway.Router"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_resources,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.ArmGateway.Router"
    },

    %{
      parent_resource: "Microsoft.Network/resourceGroups",
      table: :smalt_vault_secrets,
      key_extraction: :regex_capture,
      capture_regex: ~r/vaults\/[^\/]+\/secrets\/([^\/]+)/,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.VaultData"
    },

    %{
      parent_resource: "Microsoft.Storage/storageAccounts",
      table: :smalt_blob_blocks,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Storage/storageAccounts",
      table: :smalt_blob_containers,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Storage/storageAccounts",
      table: :smalt_blob_policy,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Storage/storageAccounts",
      table: :smalt_blob_snapshots,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Storage/storageAccounts",
      table: :smalt_blobs,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.DataPlane.BlobStorage"
    },

    %{
      parent_resource: "Microsoft.Storage/storageAccounts",
      table: :smalt_metrics,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.Metrics"
    },

    %{
      parent_resource: "Microsoft.Storage/storageAccounts",
      table: :smalt_resources,
      key_extraction: :prefix,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.ArmGateway.Router"
    },

    %{
      parent_resource: "smalt:enclave-destroy",
      table: :smalt_metrics,
      key_extraction: :reverse_topological,
      capture_regex: nil,
      sweep_strategy: :cascade,
      owner_module: "Smalt.Enclave.State"
    }

  ]

  @doc "Every declared cascade edge, sorted by (parent_resource, table)."
  def edges, do: @cascade_edges

  @doc "Edges whose sweep target is `table`."
  def edges_for_table(table) when is_atom(table) do
    Enum.filter(@cascade_edges, &(&1.table == table))
  end

  @doc "Distinct swept tables, sorted."
  def tables do
    @cascade_edges |> Enum.map(& &1.table) |> Enum.uniq() |> Enum.sort()
  end

  @doc "Distinct parent resources with a declared teardown, sorted."
  def parent_resources do
    @cascade_edges |> Enum.map(& &1.parent_resource) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Project a (table, key) pair through the declared edges into sweep
  actions:

    * `{:prefix_sweep, table, prefix}` — binary-prefix sweep via
      Smalt.Store (caller executes: `Store.prefix_keys/2` + delete)
    * `{:tuple_delete, table, key}` — exact tuple delete
    * `{:delegate, owner_module, table, captures}` — hand-written owner
      residue (BlobStorage/VaultData/Cosmos/Enclave.State drop fns)

  Edges for other tables are untouched. regex-capture edges contribute
  an action ONLY when the capture matches `key` (a non-matching key is
  not a child of this parent).
  """
  def sweep_dispatch(table, key) when is_atom(table) do
    for edge <- edges_for_table(table), action = project(edge, key) do
      action
    end
  end

  defp project(%{key_extraction: :prefix, table: table}, key) when is_binary(key) do
    {:prefix_sweep, table, String.downcase(key) <> "/"}
  end

  defp project(%{key_extraction: :tuple_exact, table: table}, key) do
    {:tuple_delete, table, key}
  end

  defp project(
         %{key_extraction: :regex_capture, capture_regex: re, owner_module: owner, table: table},
         key
       )
       when is_binary(key) do
    case Regex.run(re, key, capture: :all_but_first) do
      nil -> nil
      captures -> {:delegate, owner, table, captures}
    end
  end

  defp project(%{key_extraction: :reverse_topological, owner_module: owner, table: table}, key) do
    {:delegate, owner, table, List.wrap(key)}
  end
end
