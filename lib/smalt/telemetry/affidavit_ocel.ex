defmodule Smalt.Telemetry.AffidavitOcel do
  @moduledoc """
  Emits the `affidavit.seal` OCEL event (registry-gated, fail-safe) through
  `Smalt.Telemetry.OcelNdjson.append/3` into the NDJSON sink.

  ## Matter-isolation law

  Object ids only: the subject SHA-256 and the engine identity hash.
  NEVER receipt payloads, sealed bytes, or secret material.

  ## Fail-safe law

  A sealing caller must never fail because its telemetry failed: a failed
  append is logged and dropped, never raised into the caller.
  """

  require Logger

  alias Smalt.Telemetry.OcelNdjson

  @doc """
  Emits one `affidavit.seal` event for a completed admission-and-seal.

  `attrs` carries `:subject_sha` (hex SHA-256 of the canonical subject,
  ids only), `:verdict` ("admitted" | "refused"), and `:engine_hash`
  (engine identity hash string). Emits a `document` object keyed by the
  subject SHA. Unknown/extra keys are ignored; missing keys are emitted
  as-is (the registry gate refuses only off-vocabulary event types).
  """
  @spec seal(keyword()) :: {:ok, String.t()} | {:ok, :dropped} | {:error, term()}
  def seal(attrs) when is_list(attrs) do
    subject_sha = attrs |> Keyword.get(:subject_sha, "") |> to_string()
    verdict = attrs |> Keyword.get(:verdict, "unknown") |> to_string()
    engine_hash = attrs |> Keyword.get(:engine_hash, "") |> to_string()

    event = %{
      "id" => "ev-affidavit-seal-#{System.unique_integer([:positive])}",
      "type" => "affidavit.seal",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => %{
        "subject_sha" => subject_sha,
        "verdict" => verdict,
        "engine_hash" => engine_hash
      }
    }

    objects = [
      %{"id" => "document/affidavit/#{subject_sha}", "type" => "document", "attributes" => %{}}
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
          Logger.warning(
            "Smalt.Telemetry.AffidavitOcel: append failed, dropping: #{inspect(reason)}"
          )

          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("Smalt.Telemetry.AffidavitOcel: emission failed: #{Exception.message(e)}")
        {:error, {:emission_failed, Exception.message(e)}}
    end
  end
end
