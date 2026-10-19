defmodule SmaltTest.RouteCites do
  @moduledoc """
  Compile-time atom registry mapping `route_key` -> `{Router, handler, arity}`.

  Cites name SYMBOLS, not text positions (v26.10.18 B6, apiversion-refusal
  draft): a citation is valid iff the MFA exists in the Router's compiled
  debug_info, so router line insertions can never rot a cite. The previous
  `router.ex:LINE` cite system had to be re-anchored by hand on every router
  insertion (2026-10-17 was the second such event).

  Consumers:

    - `test/apiversion_matrix_test.exs` — row cites are route_keys; the cite
      fence calls `assert_cites_resolve!/0`.
    - `test/wire_tier_refusal_sweep_test.exs` — the type -> ARM path resolver
      consumes `route_key_for_type!/1` and asserts `assert_path_coverage!/1`
      at compile time (module attribute), so a newly admitted type without a
      resolver case fails the suite at LOAD naming the gap.

  New admitted child types need exactly one registry row here (plus, where a
  dedicated path shape exists, one resolver case) — not a registry row + a
  path case + a file:line cite string.
  """

  import ExUnit.Assertions

  @router Smalt.ArmGateway.Router

  # ===========================================================================
  # The registry: route_key -> {module, fun, arity}
  # ===========================================================================
  #
  # Every parented row cites the same shared `handle_parented_child/7` route
  # symbol; every dedicated child row cites `handle_child_put/5`. The cite
  # names the code path exercised, not a text position.
  @route_cites %{
    # Generic provider PUT route (single-segment admitted types) + resource
    # groups (registry type Microsoft.Resources/resourceGroups).
    generic_provider_put: {Smalt.ArmGateway.Router, :handle_resource_put, 5},
    rg_put: {Smalt.ArmGateway.Router, :handle_rg_put, 3},
    # Dedicated child routes (handle_child_put/5).
    subnet_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
    vault_keys_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
    blob_services_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
    containers_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
    immutability_policies_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
    # Parented-child routes (handle_parented_child/7), including the cosmos
    # children (handle_parented_child delegates to handle_cosmos_child_put/5
    # on the sql* prefix) and the vault-secrets cross-plane route.
    vault_secrets_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
    cosmos_sqldatabases_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
    cosmos_sqlcontainers_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
    sb_queues_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
    sb_topics_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
    sb_subscriptions_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
    eh_eventhubs_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
    eh_consumergroups_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
    vnet_links_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7}
  }

  def route_cites, do: @route_cites

  # ===========================================================================
  # Type classification: resource type -> route_key (mirrors the router's
  # declared route shapes; dedicated child + parented types are enumerated,
  # single-segment types ride the generic provider route).
  # ===========================================================================

  @child_type_keys %{
    "Microsoft.Network/subnets" => :subnet_put,
    "Microsoft.KeyVault/vaults/keys" => :vault_keys_put,
    "Microsoft.Storage/storageAccounts/blobServices" => :blob_services_put,
    "Microsoft.Storage/storageAccounts/blobServices/containers" => :containers_put,
    "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies" =>
      :immutability_policies_put
  }

  @parented_type_keys %{
    "Microsoft.KeyVault/vaults/secrets" => :vault_secrets_put,
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases" => :cosmos_sqldatabases_put,
    "Microsoft.DocumentDB/databaseAccounts/sqlContainers" => :cosmos_sqlcontainers_put,
    "Microsoft.ServiceBus/namespaces/queues" => :sb_queues_put,
    "Microsoft.ServiceBus/namespaces/topics" => :sb_topics_put,
    "Microsoft.ServiceBus/namespaces/topics/subscriptions" => :sb_subscriptions_put,
    "Microsoft.EventHub/namespaces/eventhubs" => :eh_eventhubs_put,
    "Microsoft.EventHub/namespaces/eventhubs/consumergroups" => :eh_consumergroups_put,
    "Microsoft.Network/privateDnsZones/virtualNetworkLinks" => :vnet_links_put
  }

  @doc """
  Classify an admitted resource type into its route_key. Returns
  `{:ok, key} | {:error, {:unrouted_type, type}}`.
  """
  def route_key_for_type(type) do
    cond do
      Map.has_key?(@child_type_keys, type) ->
        {:ok, Map.fetch!(@child_type_keys, type)}

      Map.has_key?(@parented_type_keys, type) ->
        {:ok, Map.fetch!(@parented_type_keys, type)}

      true ->
        case String.split(type, "/", parts: 2) do
          # Compile-freeze unblock (2026-10-18, lane b-await-migration,
          # minimal): String.contains?/2 is not guard-legal, so the "/" check
          # moves to the body — identical classification, compiles clean.
          [ns, leaf] when leaf != "" and ns != nil ->
            if String.contains?(leaf, "/"),
              do: {:error, {:unrouted_type, type}},
              else: {:ok, :generic_provider_put}

          _ ->
            {:error, {:unrouted_type, type}}
        end
    end
  end

  @doc "Bang variant: raises naming the type, never skips it."
  def route_key_for_type!(type) do
    case route_key_for_type(type) do
      {:ok, key} ->
        key

      {:error, reason} ->
        raise ArgumentError,
              "no route_key classification for admitted type #{type}: #{inspect(reason)} — " <>
                "extend SmaltTest.RouteCites, never skip the type"
    end
  end

  @doc """
  Compile-time path-coverage fence: every admitted type must resolve to a
  route_key the resolver covers. Raises naming the uncovered types (suite
  fails at LOAD), returns `:ok` otherwise — call from a module attribute.
  """
  def assert_path_coverage!(covered_keys, types \\ Smalt.Registry.admitted_resource_types()) do
    gaps =
      for type <- types do
        case route_key_for_type(type) do
          {:ok, key} ->
            if MapSet.member?(covered_keys, key), do: [], else: [{type, key, :uncovered_key}]

          {:error, {:unrouted_type, ^type}} ->
            [{type, nil, :unclassified}]
        end
      end
      |> List.flatten()

    assert gaps == [],
           "admitted types with no resolver path coverage (add one registry row + one " <>
             "resolver case, never skip the type): #{inspect(gaps)}"

    :ok
  end

  # ===========================================================================
  # The cite fence: introspection of the Router beam's abstract_code chunk —
  # fails structurally when a handler is renamed/deleted, never when lines
  # are inserted.
  # ===========================================================================

  @doc """
  Assert every registry cite resolves to a live Router symbol. Handlers are
  `defp`, so this reads the compiled module's `abstract_code` debug_info
  chunk instead of `function_exported?/3`.
  """
  def assert_cites_resolve! do
    {:module, router} = Code.ensure_loaded(@router)
    defs = handler_defs(router)

    for {route_key, {mod, fun, arity}} <- @route_cites do
      assert mod == router

      assert MapSet.member?(defs, {fun, arity}),
             "stale citation #{route_key}: #{inspect({mod, fun, arity})} " <>
               "no longer exists in Router — the handler was renamed/removed; " <>
               "re-derive the cite, never re-anchor a line"
    end

    :ok
  end

  @doc "Set of {fun, arity} defined by `mod`, from its beam abstract_code."
  def handler_defs(mod) do
    {:ok, {_, [abstract_code: {:raw_abstract_v1, code}]}} =
      :beam_lib.chunks(:code.which(mod), [:abstract_code])

    for {:function, _anno, fun, arity, _clauses} <- code, into: MapSet.new(), do: {fun, arity}
  end
end
