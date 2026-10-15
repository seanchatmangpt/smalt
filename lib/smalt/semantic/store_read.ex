defmodule Smalt.Semantic.StoreRead do
  @moduledoc """
  Manual Ash read path over `Smalt.Store` (the substrate's own ETS tables).

  This is the read-path-over-Store contract: the semantic surface does NOT
  create a second store (no new postgres, no shadow ETS). Each semantic
  resource names its Store table via a virtual logical table and projects the
  raw string-keyed Store map into real Ash resource structs.
  """

  @behaviour Ash.Resource.ManualRead

  alias Smalt.Store

  @impl true
  def read(_data_layer_query, query, _opts, _context) do
    case query.resource do
      Smalt.Semantic.Resource ->
        {:ok, Store.list(:smalt_resources) |> Enum.map(&project_resource/1)}

      Smalt.Semantic.LedgerEntry ->
        {:ok, Store.list(:smalt_ledger_transactions) |> Enum.map(&project_ledger/1)}

      Smalt.Semantic.Evidence ->
        {:ok, ocel_deviation_rows() |> Enum.map(&project_evidence/1)}

      other ->
        {:error, "no Store projection registered for #{inspect(other)}"}
    end
  end

  # OCEL deviation ledger (lib/smalt/ocel/deviation_admission.ex): a real
  # durable file read, not a fabricated row set.
  defp ocel_deviation_rows do
    case Smalt.Ocel.DeviationAdmission.read_all(Smalt.Ocel.DeviationAdmission.default_path()) do
      {:ok, records} -> records
      {:error, _} -> []
    end
  end

  defp project_resource(record) do
    build(Smalt.Semantic.Resource, %{
      id: record["id"],
      name: record["name"],
      type: record["type"],
      location: record["location"],
      provisioning_state: get_in(record, ["properties", "provisioningState"])
    })
  end

  defp project_ledger(receipt) do
    build(Smalt.Semantic.LedgerEntry, %{
      tx_id: receipt["transactionId"],
      sub_ledger_id: receipt["subLedgerId"],
      merkle_root: receipt["merkle_root"],
      prev_hash: receipt["prev_hash"],
      data_hash: receipt["data_hash"],
      timestamp: receipt["timestamp"]
    })
  end

  defp project_evidence(record) do
    build(Smalt.Semantic.Evidence, %{
      id: record["id"],
      reference_trace_id: record["referenceTraceId"],
      candidate_trace_id: record["candidateTraceId"],
      deviating_move: record["deviatingMove"],
      fitness: record["fitness"],
      timestamp: record["timestamp"],
      status: record["status"] || "observed"
    })
  end

  # Builds a real Ash record struct carrying the required __metadata__.
  defp build(resource, attrs) do
    resource
    |> struct(attrs)
    |> Ash.Resource.set_metadata(%{})
  end
end
