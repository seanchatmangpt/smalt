defmodule Smalt.Arm.ResourceHealth do
  @moduledoc """
  Azure Resource Health parity face (wave-6 lane w6bm, v26.10.20).
  Computed honestly from the real :smalt_resources store:
  existing row -> Available (synthetic-Available: the emulator has no
  outage signal - never a fabricated outage); unknown resource ->
  {:error, :not_found} (real parity 404).
  Transitions are NEVER synthesized: record_transition/4 is public so
  witnesses/tests driving a real state change can record one; history
  lives in :smalt_arm_health ETS (:heir 3-tuple, init owner - shadow
  table law).
  Wire helpers status_wire/1 and history_wire/1 are public for the
  post-split router mount; router patch staged at
  tmp/w6bm_router_patch.md (ROUTER HOLD respected).
  Emulator boundary: health is synthetic-Available by construction.
  """
  @table :smalt_arm_health
  @states ~w(Available Degraded Unavailable)
  def table, do: @table

  def availability_statuses(sub, rg, provider_type, res_name) do
    pt = strip_rh_suffix(provider_type)

    case find_resource(sub, rg, pt, res_name) do
      {:ok, id, _row} -> {:ok, [current(id)]}
      :error -> {:error, :not_found}
    end
  end

  def history(sub, rg, provider_type, res_name) do
    case find_resource(sub, rg, strip_rh_suffix(provider_type), res_name) do
      {:ok, id, _row} -> lookup_history(id)
      :error -> []
    end
  end

  def record_transition(sub, rg, provider_type, res_name, state, reason \\ "OperatorInitiated") do
    pt = strip_rh_suffix(provider_type)

    with {:ok, id, _row} <- find_resource(sub, rg, pt, res_name),
         :ok <- valid_state?(state) do
      ensure_table()
      rec = %{
        "availabilityState" => state,
        "summary" => reason,
        "reasonType" => reason,
        "occurredTime" => now_iso(),
        "resourceId" => id
      }

      key = {id, :erlang.unique_integer([:positive])}
      :ets.insert(@table, {key, rec})
      {:ok, rec}
    else
      :error -> {:error, :not_found}
      err -> err
    end
  end

  def status_wire(rec) do
    %{
      "availabilityState" => rec["availabilityState"],
      "summary" => rec["summary"],
      "reasonType" => rec["reasonType"],
      "occurredTime" => rec["occurredTime"],
      "id" => "#{rec["resourceId"]}/providers/Microsoft.ResourceHealth/availabilityStatuses/current"
    }
  end

  def history_wire(recs), do: Enum.map(recs, &status_wire/1)

  # --- internals ------------------------------------------------------------

  defp strip_rh_suffix(pt) do
    case :binary.split(pt, "/providers/Microsoft.ResourceHealth") do
      [head | _] -> head
      _ -> pt
    end
  end

  defp find_resource(sub, rg, provider_type, res_name) do
    prefix =
      String.downcase(
        "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{provider_type}/"
      )

    name_l = String.downcase(res_name)

    case Smalt.Store.list_prefix(:smalt_resources, prefix) do
      [] ->
        :error

      rows ->
        match =
          Enum.find(rows, fn row ->
            is_map(row) and is_binary(row["name"]) and
              String.downcase(row["name"]) == name_l
          end)

        case match do
          nil -> :error
          row -> {:ok, prefix <> row["name"], row}
        end
    end
  end

  defp current(id) do
    case lookup_history(id) do
      [] -> synthetic_available(id)
      [latest | _] -> latest
    end
  end

  defp lookup_history(id) do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_k, rec} -> rec end)
    |> Enum.filter(fn rec -> is_map(rec) and rec["resourceId"] == id end)
    |> Enum.sort_by(fn rec -> rec["occurredTime"] end)
    |> Enum.reverse()
  end

  defp synthetic_available(id) do
    %{
      "availabilityState" => "Available",
      "summary" => "Emulated resource is healthy (synthetic-Available).",
      "reasonType" => "EmulatorSynthetic",
      "occurredTime" => epoch_iso(),
      "resourceId" => id
    }
  end

  defp valid_state?(state) when state in @states, do: :ok

  defp valid_state?(_),
    do: {:error, {:invalid_state, "state must be Available | Degraded | Unavailable"}}

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        {:heir, Process.whereis(:init), []},
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp epoch_iso, do: "1970-01-01T00:00:00Z"
end
