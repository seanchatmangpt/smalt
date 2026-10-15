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
      # Lens-3 cycle 2: `struct/2` does not enforce allow_nil? on the manual
      # read path — a Store row with a nil or blank primary key projected a
      # Semantic.Resource/LedgerEntry/Evidence struct with a vacuous PK
      # (measured: RESOURCE ids=["", nil]). Same identity-vacuity class as
      # lens-2; refuse typed instead of projecting garbage.
      Smalt.Semantic.Resource ->
        rows = Store.list(:smalt_resources)

        with :ok <- refuse_non_map_rows(rows, :smalt_resources),
             :ok <- refuse_vacuous_identity(rows, "id", :smalt_resources) do
          {:ok, Enum.map(rows, &project_resource/1)}
        end

      Smalt.Semantic.LedgerEntry ->
        rows = Store.list(:smalt_ledger_transactions)

        with :ok <- refuse_non_map_rows(rows, :smalt_ledger_transactions),
             :ok <- refuse_vacuous_identity(rows, "transactionId", :smalt_ledger_transactions) do
          {:ok, Enum.map(rows, &project_ledger/1)}
        end

      Smalt.Semantic.Evidence ->
        with {:ok, records} <- ocel_deviation_rows(),
             :ok <- refuse_vacuous_identity(records, "id", :ocel_deviations) do
          {:ok, Enum.map(records, &project_evidence/1)}
        end

      other ->
        {:error, "no Store projection registered for #{inspect(other)}"}
    end
  end

  # OCEL deviation ledger (lib/smalt/ocel/deviation_admission.ex): a real
  # durable file read, not a fabricated row set. Boundary adapter (cycle-5):
  # read_all/1 decodes with Jason.decode!/1 — a malformed ledger raises that
  # boundary error is adapted to a typed refusal, never leaked through an Ash
  # read, and a real read failure is never silently read as an empty ledger.
  @spec ocel_deviation_rows() ::
          {:ok, [map()]} | {:error, {:malformed_deviation, term()} | {:read_failed, term()}}
  defp ocel_deviation_rows do
    Smalt.Ocel.DeviationAdmission.read_all(Smalt.Ocel.DeviationAdmission.default_path())
  rescue
    e in Jason.DecodeError -> {:error, {:malformed_deviation, Exception.message(e)}}
  else
    {:ok, records} -> {:ok, records}
    {:error, reason} -> {:error, {:read_failed, reason}}
  end

  # Lens-2 cycle 4: Store is an untyped key-value substrate. A non-map
  # value under a projected table's key crashed the whole Ash read
  # (FunctionClauseError in project_resource/1) — the boundary crash class
  # lens-1 closed at the ledger boundaries. Same discipline as ManualRead:
  # a malformed row refuses the read typed, never a crash, never a
  # silent skip.
  @spec refuse_non_map_rows([term()], atom()) :: :ok | {:error, String.t()}
  defp refuse_non_map_rows(rows, table) do
    case Enum.find(rows, &(!is_map(&1))) do
      nil ->
        :ok

      bad ->
        {:error,
         "semantic projection: non-map Store row under #{inspect(table)} " <>
           "(#{inspect(bad)}) — refusing read instead of projecting garbage"}
    end
  end

  # Lens-3 cycle 2: vacuous-identity fence. A projected row whose declared
  # identity key is nil or "" carries zero identity bits (R_missing_identity)
  # — refuse the read typed rather than project a PK-less struct.
  @spec refuse_vacuous_identity([map()], String.t(), atom()) :: :ok | {:error, String.t()}
  defp refuse_vacuous_identity(rows, key, surface) do
    case Enum.find(rows, fn row -> not identity?(row[key]) end) do
      nil ->
        :ok

      bad_row ->
        {:error,
         "semantic projection: vacuous identity under #{inspect(surface)} " <>
           "(#{inspect(key)} = #{inspect(bad_row[key])}) — refusing read " <>
           "instead of projecting an identity-less row"}
    end
  end

  # Lens-4 cycle 1: identity?/1 generalizes to Smalt.Projection.Identity
  # (whitespace-only / invisible-format-only ids carry zero visible
  # identity bits).
  defp identity?(id), do: Smalt.Projection.Identity.valid?(id)

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
