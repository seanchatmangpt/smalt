defmodule Smalt.Telemetry.EnclaveOcel do
  @moduledoc """
  Emits `enclave.lifecycle.stage` OCEL 2.0 events from
  `Smalt.Enclave.Lifecycle.run/2` stage completions through the closed
  registry gate (`Smalt.Ocel.EventRegistry`) and the NDJSON sink
  (`Smalt.Telemetry.OcelNdjson.append/3`).

  ## Matter-isolation law

  Object ids only: the enclave id, the fixture basename, resource ARM ids
  from the engine outcomes. NEVER fixture contents or resource bodies.

  ## Fail-safe law

  A lifecycle run must never fail because its telemetry failed: every
  emission is wrapped — a failed append is logged and dropped.
  """

  require Logger

  alias Smalt.Telemetry.OcelNdjson

  @type ctx :: %{
          required(:enclave_id) => String.t(),
          required(:fixture_id) => String.t(),
          required(:resource_ids) => [String.t()]
        }

  @doc """
  Emits one `enclave.lifecycle.stage` event for a completed stage.

  `stage` is the lifecycle atom (e.g. `:apply`); `ms` the stage's
  elapsed milliseconds; `verdict` `"ok"` or `"failed"`; `ctx` carries the
  enclave/fixture identity and (after `:apply`) the resource ids the
  stage touched. Objects: `enclave`, `fixture`, and one `resource` object
  per resource id; relationships link the event to each.
  """
  @spec stage(atom(), non_neg_integer(), String.t(), ctx()) ::
          {:ok, String.t()} | {:ok, :dropped} | {:error, term()}
  def stage(stage, ms, verdict, ctx)
      when is_atom(stage) and is_integer(ms) and is_binary(verdict) do
    event = %{
      "id" => "ev-enclave-#{stage}-#{System.unique_integer([:positive])}",
      "type" => "enclave.lifecycle.stage",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => %{"stage" => to_string(stage), "duration_ms" => ms, "verdict" => verdict}
    }

    objects = objects_for(ctx)
    relationships = Enum.map(objects, &%{"objectId" => &1["id"], "qualifier" => &1["type"]})

    event = Map.put(event, "relationships", relationships)

    try do
      case OcelNdjson.append(event, objects) do
        {:ok, _} = ok ->
          # covers {:ok, :dropped} too (registry gate); pass through unchanged
          ok

        {:error, reason} ->
          Logger.warning(
            "Smalt.Telemetry.EnclaveOcel: append failed, dropping: #{inspect(reason)}"
          )

          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("Smalt.Telemetry.EnclaveOcel: emission failed: #{Exception.message(e)}")
        {:error, {:emission_failed, Exception.message(e)}}
    end
  end

  @doc "Builds the telemetry ctx for a lifecycle run over `fixture_path`."
  @spec ctx(String.t() | Path.t(), keyword()) :: ctx()
  def ctx(fixture_path, opts \\ []) do
    fixture_id = fixture_path |> Path.basename() |> to_string()

    %{
      enclave_id: Keyword.get(opts, :enclave_id, "enclave/#{Path.basename(fixture_id, ".tf")}"),
      fixture_id: fixture_id,
      resource_ids: []
    }
  end

  @doc """
  Records the applied resource ids (engine outcome `:id`s) into `ctx` so
  post-apply stages carry resource relationships.
  """
  @spec put_resource_ids(ctx(), [map()]) :: ctx()
  def put_resource_ids(%{resource_ids: _} = ctx, outcomes) when is_list(outcomes) do
    %{ctx | resource_ids: for(%{id: id} <- outcomes, is_binary(id), do: id)}
  end

  defp objects_for(ctx) when is_map(ctx) do
    eid = ctx[:enclave_id] || ctx[:run_id] || "enclave/unknown"
    fid = ctx[:fixture_id] || ctx[:fixture] || "fixture/unknown"

    rids =
      case Map.get(ctx, :resource_ids, []) do
        ids when is_list(ids) -> for id <- ids, is_binary(id), do: id
        %{} = m -> for {_k, v} <- m, is_binary(v), do: v
        _ -> []
      end

    [%{"id" => to_string(eid), "type" => "enclave", "attributes" => %{}}] ++
      [%{"id" => to_string(fid), "type" => "fixture", "attributes" => %{}}] ++
      for rid <- rids, do: %{"id" => rid, "type" => "resource", "attributes" => %{}}
  end
end
