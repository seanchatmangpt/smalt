defmodule Smalt.Telemetry.CourtOcel do
  @moduledoc """
  Emits the `doctor.receipt` and `court.run` OCEL events (closed vocabulary
  rows that previously had no emitter) through the registry gate
  (`Smalt.Ocel.EventRegistry` via `Smalt.Telemetry.OcelNdjson.append/3`)
  and the NDJSON sink.

  ## Matter-isolation law

  Object ids only: the enclave/receipt-path identifiers and the receipt
  file path. NEVER receipt payloads (check bodies, log contents).

  ## Fail-safe law

  A doctor run or court runner must never fail because its telemetry
  failed: every emission is wrapped — a failed append is logged and
  dropped, never raised into the caller.
  """

  require Logger

  alias Smalt.Telemetry.OcelNdjson

  @doc """
  Emits one `doctor.receipt` event for a completed doctor run.

  `receipt` is the full doctor receipt map (needs `"status"` and
  `"checks"`); `receipt_path` the path the JSON receipt was written to
  (or the empty string when stdout-only). Objects: the `enclave`
  diagnostic identity and a `document` object keyed by the receipt path.
  Attributes: aggregate `status` plus the per-check verdict summary
  (`code => status`, ids only — never check bodies).
  """
  @spec doctor_receipt(map(), String.t()) ::
          {:ok, String.t()} | {:ok, :dropped} | {:error, term()}
  def doctor_receipt(receipt, receipt_path) when is_map(receipt) and is_binary(receipt_path) do
    checks = Map.get(receipt, "checks", [])

    summary =
      checks
      |> Enum.flat_map(fn
        %{"code" => code, "status" => st} when is_binary(code) -> [{code, st}]
        _ -> []
      end)
      |> Map.new()

    event = %{
      "id" => "ev-doctor-receipt-#{System.unique_integer([:positive])}",
      "type" => "doctor.receipt",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => %{
        "status" => Map.get(receipt, "status"),
        "checks" => summary
      }
    }

    objects = [
      %{"id" => "enclave/doctor", "type" => "enclave", "attributes" => %{}},
      %{"id" => receipt_path_document_id(receipt_path), "type" => "document", "attributes" => %{}}
    ]

    emit(event, objects)
  end

  @doc """
  Emits one `court.run` event for a court run.

  `attrs` carries `:run` (run number), `:verdict` ("green" |
  "not-green"), and `:stages` (list or comma string of stage names).
  `receipt_path` is the court log/receipt path (document object).
  Attributes: stages, verdicts (verdict), run number.
  """
  @spec court_run(keyword(), String.t()) :: {:ok, String.t()} | {:ok, :dropped} | {:error, term()}
  def court_run(attrs, receipt_path) when is_list(attrs) and is_binary(receipt_path) do
    run = Keyword.get(attrs, :run, 0)
    verdict = Keyword.get(attrs, :verdict, "unknown")
    stages = attrs |> Keyword.get(:stages, []) |> stages_list()

    event = %{
      "id" => "ev-court-run-#{System.unique_integer([:positive])}",
      "type" => "court.run",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => %{
        "stages" => stages,
        "verdicts" => %{"court" => to_string(verdict)},
        "run" => run
      }
    }

    objects = [
      %{"id" => receipt_path_document_id(receipt_path), "type" => "document", "attributes" => %{}}
    ]

    emit(event, objects)
  end

  # -- internals -------------------------------------------------------------

  defp emit(event, objects) do
    relationships = Enum.map(objects, &%{"objectId" => &1["id"], "qualifier" => &1["type"]})
    event = Map.put(event, "relationships", relationships)

    try do
      case OcelNdjson.append(event, objects) do
        {:ok, _} = ok ->
          # covers {:ok, :dropped} too (registry gate); pass through unchanged
          ok

        {:error, reason} ->
          Logger.warning("Smalt.Telemetry.CourtOcel: append failed, dropping: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("Smalt.Telemetry.CourtOcel: emission failed: #{Exception.message(e)}")
        {:error, {:emission_failed, Exception.message(e)}}
    end
  end

  defp receipt_path_document_id(""), do: "document/receipt/stdout"
  defp receipt_path_document_id(path), do: "document/#{path}"

  defp stages_list(stages) when is_list(stages), do: for(s <- stages, is_binary(s), do: s)
  defp stages_list(stages) when is_binary(stages), do: String.split(stages, ",", trim: true)
  defp stages_list(_), do: []
end
