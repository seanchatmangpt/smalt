defmodule Smalt.Spc.Drift do
  @moduledoc """
  SPC drift emitter: turns the `scripts/spc_gate.py` JSON verdict into
  CloudEvents 1.0 rows in `:smalt_event_messages` (`Smalt.Messaging.EventStream`,
  topic `"spc.drift"`), one per drifting metric, closing the SPC 1σ loop
  (lane 431).

  ## Laws

    * Registry-gated: emission only happens when the projected closed
      vocabulary (`Smalt.Ocel.EventRegistry`) admits `"spc.drift"` — the
      emitter is inert if the pack regen hasn't landed.
    * Fail-closed: a FAIL verdict (3σ, exit 1) is never laundered into
      telemetry. Only verdicts EVENT (1σ) and DISPATCH (2σ) emit.
    * Matter-isolation: the event `data` carries metric NAME, tier, z and
      the numeric value — never payloads, dumps or raw keys. The 3σ
      orphaned-key dump stays out of the event plane.
    * Fail-safe: nothing raises into the caller; malformed input is a
      `{:ok, :skipped}` (with a logged drop), never a crash.
  """

  require Logger

  alias Smalt.Messaging.EventStream
  alias Smalt.Ocel.EventRegistry

  @topic "spc.drift"
  @type_str "spc.drift"
  @admitted_verdicts MapSet.new(["EVENT", "DISPATCH"])

  @doc "CloudEvents topic drift events publish under."
  def topic, do: @topic

  @doc """
  Emits from the raw gate stdout (receipt JSON, possibly followed by
  `[spc] ...` status lines, which are stripped before decode). Returns
  `{:ok, ids}` (one id per emitted event), `{:ok, :skipped}` (PASS/SEEDED/
  FAIL verdicts, unknown gate, registry gate closed), or
  `{:error, {:malformed, term}}` on undecodable input.
  """
  @spec emit(String.t() | map()) :: {:ok, [String.t()]} | {:ok, :skipped} | {:error, {:malformed, term()}}
  def emit(raw) when is_binary(raw) do
    json =
      raw
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "[spc]"))
      |> Enum.join("\n")

    case Jason.decode(json)  do
      {:ok, receipt} -> emit(receipt)
      {:error, reason} -> {:error, {:malformed, reason}}
    end
  end

  def emit(receipt) when is_map(receipt) do
    cond do
      Map.get(receipt, "gate") != "spc-bands" ->
        {:ok, :skipped}

      not MapSet.member?(@admitted_verdicts, Map.get(receipt, "verdict")) ->
        # PASS / SEEDED carry no drift to emit; FAIL (3σ) is fail-closed:
        # the recipe aborts before this call and the emitter also refuses.
        {:ok, :skipped}

      not EventRegistry.event_type?(@type_str) ->
        Logger.warning("Smalt.Spc.Drift: registry gate closed for #{@type_str}, dropping")
        {:ok, :skipped}

      true ->
        ids =
          receipt
          |> Map.get("metrics", [])
          |> Enum.filter(fn m -> Map.get(m, "tier", 0) >= 1 end)
          |> Enum.map(&publish/1)

        {:ok, ids}
    end
  end

  def emit(_), do: {:ok, :skipped}

  defp publish(%{"metric" => metric} = m) do
    {:ok, id} =
      EventStream.publish(@topic, %{
        "specversion" => "1.0",
        "source" => "smalt://scripts/spc_gate.py",
        "type" => @type_str,
        "data" => %{
          "metric" => metric,
          "tier" => Map.get(m, "tier"),
          "value" => Map.get(m, "value"),
          "z" => Map.get(m, "z")
        }
      })

    id
  end

  # A tier>=1 metric row without a binary metric name is malformed; never
  # launder it (same discipline as OcelEmitter's malformed-identifier drop).
  defp publish(_), do: raise_arg_error()
  defp raise_arg_error, do: raise(ArgumentError, message: "metric row without binary \"metric\"")
end
