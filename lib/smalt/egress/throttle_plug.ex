defmodule Smalt.Egress.ThrottlePlug do
  @moduledoc """
  MOONSHOT lane 9 (throttling realism): token-bucket throttling per egress
  plane, config-gated DEFAULT-OFF.

  With no `:smalt, :throttle` entry (or `rate: nil` / `burst: nil`) the plug
  short-circuits at the top of the egress chain — no bucket math, requests
  pass through byte-identical (same posture as the APIM plane: config-driven,
  default-off). Rate/burst come from config or the SMALT_THROTTLE_RATE /
  SMALT_THROTTLE_BURST environment variables (config wins).

  When enabled, each plane bucket starts with `burst` tokens and refills at
  `rate` tokens/second. On exhaustion the plug answers the REAL-Azure 429 for
  that plane with a `retry-after` header — one typed shape per plane, from
  the existing route modules' error faces:

    * `:sb` (Event Hubs /topics plane) — the EventHubs REST JSON envelope
      `{"error":{"code":"ServerBusy",...}}`, same shape as
      `Smalt.Egress.EventHubsRestRoutes`' send_error.
    * `:storage` (blob/queue/file/table splat) — the Azure Storage XML
      `<Error><Code>ServerBusy</Code>...` envelope.
    * `:cosmos` (`/dbs` plane) — the Cosmos JSON envelope with the real
      "Request rate is large" message face.
    * every other plane — the generic JSON `{"error":{"code":...}}` face.

  Bucket state rides a dedicated public ETS table keyed by {plane, key}
  (key = first path segment — namespace granularity is not addressable at
  this plug position, so per-plane is the law). Reads and writes race under
  concurrency at the milli-token level; the gate is a realism throttle, not a
  billing ledger, so last-write-wins admission is the accepted posture.

  The clock is injectable (`config :smalt, :throttle_clock, Mod` with
  `Mod.now_ms/0`) for deterministic refill in tests; default wall clock.
  """

  @table :smalt_throttle_buckets

  import Plug.Conn

  alias Smalt.DataPlane.BlobService

  def init(opts), do: opts

  def call(conn, _opts) do
    case conf() do
      :off -> conn
      {rate, burst} -> check(conn, plane_of(conn), rate, burst)
    end
  end

  # -- config ------------------------------------------------------------------

  defp conf do
    case Application.get_env(:smalt, :throttle) do
      c when is_list(c) -> resolve(c)
      _ -> :off
    end
  end

  defp resolve(c) do
    rate = conf_int(c[:rate], "SMALT_THROTTLE_RATE")
    burst = conf_int(c[:burst], "SMALT_THROTTLE_BURST")

    if is_integer(rate) and rate > 0 and is_integer(burst) and burst > 0 do
      {rate, burst}
    else
      :off
    end
  end

  defp conf_int(nil, env), do: parse_int(System.get_env(env))
  defp conf_int(v, _env) when is_integer(v), do: v
  defp conf_int(_, _), do: nil

  defp parse_int(nil), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # -- the gate ------------------------------------------------------------------

  defp check(conn, plane, rate, burst) do
    {allowed, retry_after_s} = take_token(plane, bucket_key(conn), rate, burst, now_ms())

    if allowed do
      conn
    else
      refuse(conn, plane, retry_after_s)
    end
  end

  # -- token bucket (ETS, {plane, key} -> {milli_tokens, last_ms}) ----------------
  # Tokens are tracked in milli-units so the refill is integer math:
  # refill_milli = (now_ms - last_ms) * rate  (rate tokens/s = rate milli/ms).

  @doc """
  Takes one token from the {plane, key} bucket at wall-time `now_ms`.
  Returns `{true, 0}` on admission, `{false, retry_after_seconds}` on
  exhaustion. Public so the court drives the bucket directly with a fixed
  clock (deterministic refill, never a sleep).
  """
  def take_token(plane, key, rate, burst, now_ms) do
    :ok = ensure_table!()

    k = {plane, key}
    burst_milli = burst * 1000

    {tokens, last} =
      case :ets.lookup(@table, k) do
        [{_, t, l}] -> {t, l}
        [] -> {burst_milli, now_ms}
      end

    refilled = min(tokens + max(0, (now_ms - last) * rate), burst_milli)

    if refilled >= 1000 do
      :ets.insert(@table, {k, refilled - 1000, now_ms})
      {true, 0}
    else
      :ets.insert(@table, {k, refilled, now_ms})
      # `refilled` milli-tokens accumulate at `rate` milli/ms; the wait to a
      # full token is refilled-deficit / rate ms, floored at 1 whole second
      # (retry-after is whole seconds on the wire).
      need = 1000 - refilled
      {false, max(1, div(need, rate * 1000) + 1)}
    end
  end

  # -- clock ---------------------------------------------------------------------

  defp now_ms do
    case Application.get_env(:smalt, :throttle_clock) do
      nil -> System.system_time(:millisecond)
      mod -> mod.now_ms()
    end
  end

  # -- plane classification --------------------------------------------------------

  # Per-plane (namespace is not addressable at this plug position — the first
  # path segment is the finest key available before dispatch).
  defp plane_of(conn) do
    case conn.path_info do
      ["dbs" | _] -> :cosmos
      [seg | _] when seg in ["keys", "secrets", "certificates", "kv"] -> :kv
      ["topics" | _] -> :sb
      ["attest" | _] -> :attest
      # AZURE-FIDELITY lane 18: ARM control-plane route classes — the first
      # segment is always "subscriptions"/"providers" there, so classification
      # is by provider namespace in the full path.
      ["subscriptions" | _] -> arm_plane(conn.request_path)
      ["providers" | _] -> arm_plane(conn.request_path)
      _ -> :storage
    end
  end

  # ARM route classes; unclassified ARM shapes get :arm (generic face).
  # Note: bucket key stays the first path segment ("subscriptions"), so all
  # subscription-scoped ARM calls of one class share the class bucket — the
  # finest granularity available before dispatch.
  defp arm_plane(path) do
    cond do
      String.contains?(path, "Microsoft.ResourceGraph") -> :graph
      String.contains?(path, "Microsoft.CostManagement") -> :cost
      String.contains?(path, "Microsoft.Resources/deployments") -> :deployments
      true -> :arm
    end
  end

  defp bucket_key(conn) do
    case conn.path_info do
      [seg | _] -> seg
      [] -> ""
    end
  end

  # -- refusal faces (one typed shape per plane, from the route modules) ----------

  defp refuse(conn, plane, retry_after_s) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> plane_refusal(plane)
    |> halt()
  end

  # :storage gets the Azure Storage XML <Error> envelope — the same face
  # Smalt.EgressRouter.send_file_error/4 renders for storage-plane errors.
  defp plane_refusal(conn, :storage) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(
      429,
      ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>) <>
        BlobService.xml_escape("ServerBusy") <>
        "</Code><Message>" <>
        BlobService.xml_escape("The server is busy. Retry later (throttled).") <>
        "</Message></Error>"
    )
  end

  # :cosmos gets the real Cosmos 429 face (code 429, "Request rate is large").
  defp plane_refusal(conn, :cosmos) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        "code" => 429,
        "message" =>
          "Message: {\"errors\":[{\"severity\":\"Error\",\"code\":\"429\"," <>
            "\"message\":\"Request rate is large. More Request Charge may be available later.\"}]}"
      })
    )
  end

  # :sb gets the EventHubs REST JSON error envelope (ServerBusy), the same
  # shape Smalt.Egress.EventHubsRestRoutes.send_error/4 renders.
  defp plane_refusal(conn, :sb) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        "error" => %{
          "code" => "ServerBusy",
          "message" => "publish throttled: token bucket exhausted"
        }
      })
    )
  end

  # ARM control-plane classes get the real ARM 429 envelope (same shape the
  # ArmGateway.Router fixed-window throttle renders).
  defp plane_refusal(conn, p) when p in [:deployments, :graph, :cost, :arm] do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        "error" => %{
          "code" => "TooManyRequests",
          "message" =>
            "The request was throttled (ARM control-plane #{p} plane). " <>
              "Retry after the period specified in the retry-after response header."
        }
      })
    )
  end

  # :kv / :attest / unknown planes get the generic router JSON error face.
  defp plane_refusal(conn, _other) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{"error" => %{"code" => "ServerBusy", "message" => "throttled"}})
    )
  end

  # -- lifecycle -------------------------------------------------------------------

  @doc "Ensures the bucket table exists. Idempotent."
  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "Drops all bucket state (courts start from a clean bucket)."
  def reset! do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end
end
