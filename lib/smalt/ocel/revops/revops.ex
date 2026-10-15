defmodule Smalt.Ocel.RevOps do
  @moduledoc """
  Read-only Ash domain exposing a RevOps surface over smalt's OCEL feed:
  traces, conformance fitness verdicts, and admitted deviations —
  composed per the ash-ocel-revops-surface-factory-pack (r75 candidate
  structures OcelTimeline / ProcessConendance / ValueEvidence) with the
  executable manufacturer vocabulary of ash-revops-structural-factory-pack
  (ar:AshResource): OcelTimeline, ProcessConformance, ValueEvidence.
  Projection inputs live in `gen/`; see
  docs/PACK_INTEGRATION/ash-ocel-revops.md for the receipt.

  Read-only law: no create/update/destroy actions exist anywhere in the
  domain. Every record is derived from a real file (the NDJSON sink or the
  deviation ledger) at read time.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Smalt.Ocel.RevOps.OcelTrace
    resource Smalt.Ocel.RevOps.OcelDeviation
    resource Smalt.Ocel.RevOps.FitnessVerdict
  end

  @doc """
  Groups an assembled OCEL document's events into `{trace_id, events}`
  pairs, keyed by the first relationship objectId of each event (events
  without relationships fall under the positional key `trace-<index>`).
  Stable, deterministic, first-appearance order.
  """
  @spec trace_groups(map()) :: [{String.t(), [map()]}]
  def trace_groups(%{"ocel:events" => events}) when is_list(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, i} -> {trace_key(event, i), event} end)
    |> Enum.reduce(%{}, fn {key, event}, acc ->
      Map.update(acc, key, [event], &(&1 ++ [event]))
    end)
    |> then(fn grouped ->
      order =
        events
        |> Enum.with_index()
        |> Enum.map(fn {e, i} -> trace_key(e, i) end)
        |> Enum.uniq()

      Enum.map(order, &{&1, Map.fetch!(grouped, &1)})
    end)
  end

  def trace_groups(_), do: []

  @doc "Assembles the NDJSON sink at `path` into a document (delegates to the real sink)."
  @spec read_document(String.t()) :: {:ok, map()} | {:error, [map()]}
  def read_document(path), do: Smalt.Telemetry.OcelNdjson.read_document(path)

  defp trace_key(event, i) do
    case get_in(event, ["relationships", Access.at(0), "objectId"]) do
      key when is_binary(key) and key != "" -> key
      _ -> "trace-#{i}"
    end
  end
end
