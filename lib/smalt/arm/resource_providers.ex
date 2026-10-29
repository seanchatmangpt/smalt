defmodule Smalt.Arm.ResourceProviders do
  @moduledoc """
  ARM resource-provider faces (wave-6 lane w6ac, v26.10.20).

  Every namespace smalt's ARM actually serves (seeded from
  `Smalt.Registry.admitted_resource_types/0` — no invented namespaces)
  renders as a provider with `registrationState` and its resource types
  with their latest admitted api-version (KD-78 lattice,
  `Smalt.Registry.latest_version/1`).

  Registration faces:

  - `register/1` / `unregister/1` return the record in the transitional
    state (`"Registering"`/`"Unregistering"`); the terminal state
    (`"Registered"`/`"Unregistered"`) surfaces on the NEXT read
    (`provider/1`, `providers_wire/0`) — immediate-transition emulation of
    real ARM's async RP registration. No timers, no Process.sleep.
  - Unknown namespace → `{:error, :invalid_namespace}` (wire face 400
    `InvalidResourceNamespace`; router patch staged in
    `tmp/w6ac_router_patch.md` — ROUTER HOLD respected).
  """

  @table :smalt_arm_providers

  @type state :: :registered | :unregistered | :registering | :unregistering
  @type provider_record :: %{namespace: String.t(), state: state(), resource_types: [String.t()]}

  @spec providers() :: [provider_record()]
  def providers do
    ensure_seeded()
    Enum.map(:ets.tab2list(@table), fn {_ns, rec} -> rec end)
  end

  @spec provider(String.t()) :: {:ok, provider_record()} | {:error, :not_found}
  def provider(ns) when is_binary(ns) do
    ensure_seeded()

    case :ets.lookup(@table, ns) do
      [{^ns, rec}] ->
        rec = advance(rec)
        :ets.insert(@table, {ns, rec})
        {:ok, rec}

      [] ->
        {:error, :not_found}
    end
  end

  def register(ns) when is_binary(ns) do
    ensure_seeded()
    transition_to(ns, :registering)
  end

  def unregister(ns) when is_binary(ns) do
    ensure_seeded()
    transition_to(ns, :unregistering)
  end

  defp transition_to(ns, transitional) do
    case :ets.lookup(@table, ns) do
      [{^ns, rec}] ->
        :ets.insert(@table, {ns, %{rec | state: transitional}})
        {:ok, %{rec | state: transitional}}

      [] ->
        {:error, :invalid_namespace}
    end
  end

  defp advance(%{state: s} = rec) when s == :registering do
    %{rec | state: :registered}
  end

  defp advance(%{state: s} = rec) when s == :unregistering do
    %{rec | state: :unregistered}
  end

  defp advance(rec), do: rec

  # -- Wire-format helpers (public; post-split router patch is ~3 lines) -------

  @doc """
  Wire record for a provider: %{namespace, registrationState, resourceTypes:
  [%{resourceType, apiVersions}]} — resourceType path is everything after the
  namespace segment.
  """
  @spec provider_wire(provider_record()) :: map()
  def provider_wire(rec) do
    rts =
      rec.resource_types
      |> Enum.map(fn type ->
        path = type |> String.split("/", parts: 2) |> Enum.at(1)
        %{"resourceType" => path, "apiVersions" => [Smalt.Registry.latest_version(type)]}
      end)
      |> Enum.sort_by(& &1["resourceType"])

    %{
      "namespace" => rec.namespace,
      "registrationState" => state_wire(rec.state),
      "resourceTypes" => rts
    }
  end

  @doc """
  GET /subscriptions/{sub}/providers body — %{"value" => [wire...]}, skipping
  unregistered providers (real-ARM default filter). Applies the
  read-triggered transition like any other read.
  """
  @spec providers_wire() :: %{optional(String.t()) => [map()]}
  def providers_wire do
    %{
      "value" =>
        providers()
        |> Enum.map(fn rec ->
          rec = advance(rec)
          :ets.insert(@table, {rec.namespace, rec})
          rec
        end)
        |> Enum.filter(fn rec -> rec.state in [:registered, :registering] end)
        |> Enum.map(&provider_wire/1)
        |> Enum.sort_by(& &1["namespace"])
    }
  end

  @doc "Typed error body for {:error, :invalid_namespace}: 400 InvalidResourceNamespace."
  @spec invalid_namespace_error(String.t()) :: map()
  def invalid_namespace_error(ns) do
    %{
      "error" => %{
        "code" => "InvalidResourceNamespace",
        "message" => "Resource provider namespace '#{ns}' is not served by this resource manager."
      }
    }
  end

  defp state_wire(:registered), do: "Registered"
  defp state_wire(:unregistered), do: "Unregistered"
  defp state_wire(:registering), do: "Registering"
  defp state_wire(:unregistering), do: "Unregistering"

  defp ensure_seeded do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :set,
          :public,
          {:heir, Process.whereis(:init), []},
          read_concurrency: true
        ])

        Enum.each(Smalt.Registry.admitted_resource_types(), fn type ->
          ns = type |> String.split("/", parts: 2) |> hd()
          upsert_type(ns, type)
        end)

      _ ->
        :ok
    end
  end

  defp upsert_type(ns, type) do
    case :ets.lookup(@table, ns) do
      [{^ns, rec}] ->
        :ets.insert(@table, {ns, %{rec | resource_types: Enum.uniq([type | rec.resource_types])}})

      [] ->
        rec = %{namespace: ns, state: :registered, resource_types: [type]}
        :ets.insert(@table, {ns, rec})
    end
  end
end
