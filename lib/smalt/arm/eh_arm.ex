defmodule Smalt.Arm.EhArm do
  @moduledoc """
  EH ARM namespace-capability face (v26.10.19 wave-3, CREATE lane w3o).

  Read-only enrichment over the ARM resource store and the Event Hubs data
  plane (`Smalt.Messaging.EventHubs` partition records) — never writes.

  Two faces:

  - **Namespace status face**: `namespace_status/1` derives the real-ARM
    namespace `status` face (`Active`/`Creating`) from a stored namespace
    record, honoring an explicit stored `status` verbatim (a future
    Creating-face lane can stage a record with `status => "Creating"` and
    this face reports it without a code change).
  - **Enriched hub GET**: `enrich_hub/2` merges the engine's partition
    truth — `partitionIds`, per-partition
    `beginningSequenceNumber`/`lastEnqueuedSequenceNumber`/
    `lastEnqueuedOffset` — into the stored hub record. Partition rows are
    read from `:smalt_eh_partitions` read-only; a hub with no traffic
    still renders the partition list (sequences face `nil`), matching
    real Azure (partition metrics absent until first send).

  The geo-DR alias surface is deliberately NOT wired here: the geo-DR
  lane's `lib/smalt/messaging/eh_geo_dr.ex` has not landed, and alias
  routes without an engine refuse typed (`UNSUPPORTED`), which would mint
  a loud fake surface. Wiring lands with the geo-DR lane.
  """

  alias Smalt.Messaging.EhGeoDr
  alias Smalt.Messaging.EventHubs, as: EH

  @partitions :smalt_eh_partitions
  @ns_type "Microsoft.EventHub/namespaces"

  # -- Namespace status face ---------------------------------------------------

  @doc """
  Namespace status face for a stored namespace record.

  Returns `"Active"`, `"Creating"`, or `"Succeeded"` per the stored record:
  an explicit stored `properties.status` wins verbatim; otherwise a
  `provisioningState` of `"Creating"` reports `"Creating"`; anything else
  reports `"Active"`. `nil` record (no namespace) reports `nil`.
  """
  @spec namespace_status(map() | nil) :: String.t() | nil
  def namespace_status(nil), do: nil

  def namespace_status(record) when is_map(record) do
    props = record |> props_of()

    case props do
      %{"status" => status} when is_binary(status) ->
        status

      %{"provisioningState" => "Creating"} ->
        "Creating"

      _ ->
        "Active"
    end
  end

  @doc """
  Full namespace face map: `status` face merged over the stored properties,
  suitable for `Map.merge(properties, namespace_face(record))` in a route
  handler. `nil` record → `%{}`.
  """
  @spec namespace_face(map() | nil) :: map()
  def namespace_face(nil), do: %{}

  def namespace_face(record) when is_map(record) do
    case namespace_status(record) do
      status -> %{"status" => status}
    end
  end

  @doc """
  Look up a namespace record by subscription/resource-group/name using the
  router's dual storage convention (providers-prefixed and unprefixed keys,
  downcased) — mirrors `handle_parented_child/7`'s parent resolution,
  read-only.
  """
  @spec get_namespace(String.t(), String.t(), String.t()) :: {:ok, map()} | :error
  def get_namespace(sub_id, rg_name, ns) do
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")
    rel = "namespaces/#{ns}"

    with {:ok, key} <- find_key([base <> "providers/#{@ns_type}/#{rel}", base <> rel]) do
      Smalt.Store.get(:smalt_resources, key)
    end
  end

  # -- Enriched hub GET ----------------------------------------------------------

  @doc """
  Enrich a stored hub record with the data plane's partition truth.

  Merges into `properties`:

  - `partitionIds` — `["0", "1", ...]` from the record's `partitionCount`
    (or the length of a stored `partitionIds`).
  - `partitionMetrics` — per partition: `beginningSequenceNumber`,
    `lastEnqueuedSequenceNumber`, `lastEnqueuedOffset`,
    `lastEnqueuedTimeUtc` (epoch ms) or `nil` faces when the partition has
    no traffic yet.

  Read-only: partition rows are read from `:smalt_eh_partitions`; nothing
  is written to the store or the data plane. A record without a
  partition count is returned unchanged.
  """
  @spec enrich_hub(map(), String.t()) :: map()
  def enrich_hub(record, hub) when is_map(record) and is_binary(hub) do
    props = props_of(record)

    with count when count > 0 <- partition_count(props) do
      metrics = partition_metrics(hub, count)

      put_in(
        record,
        ["properties"],
        props
        |> Map.put("partitionIds", Enum.map(0..(count - 1), &Integer.to_string/1))
        |> Map.put("partitionMetrics", metrics)
      )
    else
      _ -> record
    end
  end

  @doc """
  Partition count for a hub record: stored `partitionCount`, else the
  length of stored `partitionIds`, else 0.
  """
  @spec partition_count(map()) :: non_neg_integer()
  def partition_count(props) when is_map(props) do
    case props do
      %{"partitionCount" => n} when is_integer(n) and n > 0 -> n
      %{"partitionCount" => n} when is_binary(n) -> String.to_integer(n)
      %{"partitionIds" => ids} when is_list(ids) -> length(ids)
      _ -> 0
    end
  end

  @doc """
  Per-partition engine truth for partitions `0..count-1` of `hub`.

  Partition rows are keyed `"…/<hub>/<partition-id>"` in
  `:smalt_eh_partitions` (KD-68: partition identity is hub-scoped, so the
  key's hub segment is matched as a suffix, shortest key wins when several
  namespace spellings exist). Read-only `:ets.select` — precedent:
  `Smalt.Messaging.EventHubs.receive_events/3` reads the same table
  directly.
  """
  @spec partition_metrics(String.t(), pos_integer()) :: map()
  def partition_metrics(hub, count) when is_binary(hub) and count > 0 do
    rows = :ets.tab2list(@partitions)

    for i <- 0..(count - 1) do
      pid = Integer.to_string(i)
      suffix = "/#{hub}/#{pid}"

      row =
        case rows
             |> Enum.filter(fn {key, _} -> is_binary(key) and match_suffix?(key, hub, suffix) end) do
          [] -> nil
          candidates -> candidates |> Enum.sort_by(fn {k, _} -> byte_size(k) end) |> hd()
        end

      case row do
        {key, %{"seq" => seq} = r} ->
          last = EH.last_enqueued(key)

          {pid,
           %{
             "beginningSequenceNumber" => 0,
             "lastEnqueuedSequenceNumber" => Map.get(r, "seq", seq),
             "lastEnqueuedOffset" => last["offset"] || nil,
             "lastEnqueuedTimeUtc" => last["enqueued"] || nil
           }}

        nil ->
          {pid,
           %{
             "beginningSequenceNumber" => 0,
             "lastEnqueuedSequenceNumber" => nil,
             "lastEnqueuedOffset" => nil,
             "lastEnqueuedTimeUtc" => nil
           }}
      end
    end
    |> Map.new()
  end

  # -- Geo-DR alias ARM face -----------------------------------------------------

  @doc """
  Geo-DR alias ARM envelope: build the
  `Microsoft.EventHub/namespaces/disasterRecoveryConfigs` resource record for
  an engine alias record (`Smalt.Messaging.EhGeoDr`), mirroring the cg bridge's
  envelope pattern: engine record fields → camelCase ARM properties.
  `payload` (raw PUT body, may be `nil`) is deep-merged verbatim into
  properties.
  """
  @spec alias_envelope(String.t(), String.t(), String.t(), String.t(), map(), map() | nil) :: map()
  def alias_envelope(sub_id, rg_name, ns, alias_name, rec, payload \\ nil) do
    id =
      String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}") <>
        "/providers/Microsoft.EventHub/namespaces/#{ns}/disasterRecoveryConfigs/#{alias_name}"

    engine_props = %{
      "provisioningState" => alias_arm_state(rec["provisioning_state"]),
      "roleByNamespace" =>
        Map.new(rec["role_by_ns"] || %{}, fn {n, role} -> {n, Atom.to_string(role)} end)
    }

    payload_props = payload_props(payload)

    %{
      "id" => id,
      "name" => "#{ns}/#{parent_slash_name(ns, alias_name)}",
      "type" => "Microsoft.EventHub/namespaces/disasterRecoveryConfigs",
      "location" => Map.get(payload || %{}, "location", "smalt-local"),
      "properties" => Map.merge(engine_props, payload_props)
    }
  end

  # Real ARM names disasterRecoveryConfigs "<ns>/<alias>"; when the caller
  # passes the alias with its namespace prefix already, render verbatim.
  defp parent_slash_name(_ns, name), do: name

  # Engine states ("FailedOver"/"Broken") render verbatim; paired-but-live
  # aliases face as "Succeeded" (real ARM reports Succeeded for an
  # established pairing).
  defp alias_arm_state(state) when state in ["FailedOver", "Broken"], do: state
  defp alias_arm_state(_), do: "Succeeded"

  defp payload_props(%{"properties" => p}) when is_map(p), do: p
  defp payload_props(_), do: %{}

  @doc """
  Engine-backed alias lifecycle for the router's `disasterRecoveryConfigs`
  routes. `verb` in `:get | :list | :delete | :failover | :break`.

  Returns:

  - `{:ok, rec}` — engine record (single alias) or list (LIST).
  - `{:error, face}` — typed face with `status`/`code`/`description` for
    `send_arm_error/4` translation (404 alias-not-found, 409 wrong-state
    for failover/break).
  """
  @spec alias_lifecycle(atom(), String.t()) ::
          {:ok, map() | [map()]}
          | {:error, %{status: pos_integer(), code: String.t(), description: String.t()}}
  def alias_lifecycle(:get, alias_name) do
    EhGeoDr.get_alias(alias_name)
  end

  def alias_lifecycle(:list, _alias_name) do
    {:ok, EhGeoDr.list_aliases()}
  end

  def alias_lifecycle(:delete, alias_name) do
    case EhGeoDr.get_alias(alias_name) do
      {:ok, _rec} ->
        :ok = EhGeoDr.delete_alias(alias_name)
        {:ok, nil}

      {:error, face} ->
        {:error, face}
    end
  end

  def alias_lifecycle(verb, alias_name) when verb in [:failover, :break] do
    case verb do
      :failover -> EhGeoDr.failover(alias_name)
      :break -> EhGeoDr.break_pairing(alias_name)
    end
  end

  @doc """
  PUT face for an alias: idempotent create/update through the engine, returns
  the engine record. `payload` is the raw PUT body map (`nil` tolerated —
  the engine refuses an empty primary/partner at the ARM layer here with a
  typed 400 face).
  """
  @spec alias_put(String.t(), map() | nil) ::
          {:ok, map()} | {:error, %{status: pos_integer(), code: String.t(), description: String.t()}}
  def alias_put(alias_name, payload) do
    props = payload_props(payload)
    primary = Map.get(props, "primaryNamespaceId") || Map.get(props, "primary_namespace_id")
    partner = Map.get(props, "partnerNamespace") || Map.get(props, "partner_namespace_id")

    with :ok <- require_pair(primary, partner),
         {:ok, rec} <- EhGeoDr.create_or_update_alias(alias_name, primary, partner) do
      {:ok, rec}
    else
      {:error, face} -> {:error, face}
    end
  end

  defp require_pair(nil, _partner) do
    {:error, %{status: 400, code: "InvalidResourceShape", description: "primaryNamespaceId is required"}}
  end

  defp require_pair(_primary, nil) do
    {:error, %{status: 400, code: "InvalidResourceShape", description: "partnerNamespace is required"}}
  end

  defp require_pair(_, _), do: :ok

  # Key must end with the partition id and carry the hub as the preceding
  # segment (KD-68 hub-scoped identity): "<...>/<hub>/<pid>" or exactly
  # "<hub>/<pid>".
  defp match_suffix?(key, _hub, suffix) do
    key == String.trim_leading(suffix, "/") or String.ends_with?(key, suffix)
  end

  defp find_key(candidates) do
    candidates
    |> Enum.find(:error, fn key ->
      match?({:ok, _}, Smalt.Store.get(:smalt_resources, key))
    end)
    |> case do
      :error -> :error
      key -> {:ok, key}
    end
  end

  defp props_of(record) when is_map(record), do: Map.get(record, "properties") || %{}
end
