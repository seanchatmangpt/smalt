defmodule Smalt.Webhooks.Signature do
  @moduledoc """
  Webhook signature signing and verification.

  Stripe scheme: header `t=<unix>,v1=<hex>[,v1=<hex>...]`, HMAC-SHA256 over
  `"\#{t}.\#{payload}"`, default tolerance 300s, constant-time compare, any v1 may match.

  Svix scheme (Lithic/Column style): headers `svix-id`, `svix-timestamp`,
  `svix-signature` (`v1,<base64>` space-separated), HMAC-SHA256 over
  `"\#{id}.\#{ts}.\#{payload}"` keyed with the base64-decoded secret (`whsec_` prefix stripped).
  """

  @default_tolerance 300

  @type error ::
          :missing_header | :malformed_header | :no_valid_signature | :timestamp_stale

  # ---- Stripe ----

  @spec stripe_sign(binary(), binary(), integer()) :: binary()
  def stripe_sign(payload, secret, timestamp) do
    hmac_hex(secret, "#{timestamp}.#{payload}")
  end

  @spec stripe_header(binary(), binary(), integer()) :: binary()
  def stripe_header(payload, secret, timestamp) do
    "t=#{timestamp},v1=#{stripe_sign(payload, secret, timestamp)}"
  end

  @spec verify_stripe(binary(), binary() | nil, binary(), keyword()) :: :ok | {:error, error()}
  def verify_stripe(payload, header, secret, opts \\ [])

  def verify_stripe(_payload, nil, _secret, _opts), do: {:error, :missing_header}
  def verify_stripe(_payload, "", _secret, _opts), do: {:error, :missing_header}

  def verify_stripe(payload, header, secret, opts) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    now = Keyword.get(opts, :now, System.os_time(:second))

    with {:ok, t, sigs} <- parse_stripe(header),
         :ok <- check_signatures(sigs, stripe_sign(payload, secret, t)),
         :ok <- check_tolerance(t, now, tolerance) do
      :ok
    end
  end

  @doc false
  def parse_stripe(header) do
    pairs =
      header
      |> String.split(",", trim: true)
      |> Enum.map(fn part ->
        case String.split(String.trim(part), "=", parts: 2) do
          [k, v] -> {k, v}
          _ -> :bad
        end
      end)

    cond do
      Enum.member?(pairs, :bad) ->
        {:error, :malformed_header}

      true ->
        with {_, ts} <- List.keyfind(pairs, "t", 0),
             {t, ""} <- Integer.parse(ts),
             sigs when sigs != [] <- for({"v1", v} <- pairs, do: v) do
          {:ok, t, sigs}
        else
          _ -> {:error, :malformed_header}
        end
    end
  end

  # ---- Svix-style (Lithic / Column) ----

  @spec svix_sign(binary(), binary(), binary(), integer()) :: binary()
  def svix_sign(payload, secret, msg_id, timestamp) do
    key = svix_key(secret)
    "v1," <> Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{msg_id}.#{timestamp}.#{payload}"))
  end

  @spec verify_svix(binary(), map(), binary(), keyword()) :: :ok | {:error, error()}
  def verify_svix(payload, headers, secret, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    now = Keyword.get(opts, :now, System.os_time(:second))

    with {:ok, id} <- fetch(headers, "svix-id"),
         {:ok, ts_s} <- fetch(headers, "svix-timestamp"),
         {:ok, sig_h} <- fetch(headers, "svix-signature"),
         {ts, ""} <- Integer.parse(ts_s) |> ok_or(:malformed_header),
         expected = svix_sign(payload, secret, id, ts),
         candidates = String.split(sig_h, " ", trim: true),
         :ok <- check_signatures(candidates, expected),
         :ok <- check_tolerance(ts, now, tolerance) do
      :ok
    end
  end

  defp ok_or({_, _} = r, _), do: r
  defp ok_or(_, err), do: {:error, err}

  defp fetch(headers, key) do
    case Map.get(headers, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :missing_header}
    end
  end

  defp svix_key("whsec_" <> rest), do: decode_or_raw(rest)
  defp svix_key(other), do: decode_or_raw(other)

  defp decode_or_raw(s) do
    case Base.decode64(s) do
      {:ok, k} -> k
      :error -> s
    end
  end

  # ---- shared ----

  defp hmac_hex(secret, data),
    do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)

  defp check_signatures(candidates, expected) do
    # Evaluate every candidate (no short-circuit) to keep timing independent of position.
    matched =
      Enum.reduce(candidates, false, fn c, acc -> secure_equal?(c, expected) or acc end)

    if matched, do: :ok, else: {:error, :no_valid_signature}
  end

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_equal?(_, _), do: false

  defp check_tolerance(t, now, tolerance) do
    if abs(now - t) <= tolerance, do: :ok, else: {:error, :timestamp_stale}
  end
end
