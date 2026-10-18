defmodule Smalt.Amqp.SasVerifier do
  @moduledoc """
  CBS put-token SharedAccessSignature verification for the Service Bus
  emulator dialect.

  Parses and verifies `SharedAccessSignature sr=..&sig=..&se=..&skn=..` tokens
  with exactly the four unique fields, constant-time HMAC-SHA256 signature
  compare, audience-scope validation and an expiry window of at most
  86_400 seconds.

  Returns `{:ok, claims}` or `{:error, {status_code, description}}`.
  """

  @max_token_bytes 8_192
  @max_audience_chars 1_024
  @max_token_lifetime 86_400
  @min_key_bytes 32
  @required_skn "RootManageSharedAccessKey"
  @default_endpoint "sb://127.0.0.1:5672"

  defmodule Audience do
    @moduledoc false
    defstruct [:scheme, :host, :port]

    @type t :: %__MODULE__{
            scheme: String.t() | nil,
            host: String.t() | nil,
            port: :inet.port_number() | nil
          }
  end

  @type audience_config :: Audience.t() | String.t()

  @type claims :: %{
          required(:sr) => String.t(),
          required(:sig) => String.t(),
          required(:se) => integer(),
          required(:skn) => String.t(),
          required(:audience) => String.t()
        }

  @doc """
  Verifies `token` against the configured endpoint (see `endpoint/0`) and
  shared key (see `shared_key/0`).
  """
  @spec verify(String.t()) :: {:ok, claims()} | {:error, {integer(), String.t()}}
  def verify(token), do: verify(token, endpoint(), System.system_time(:second))

  @spec verify(String.t(), audience_config(), integer()) ::
          {:ok, claims()} | {:error, {integer(), String.t()}}
  def verify(token, audience_config, now \\ System.system_time(:second))

  def verify(token, audience_config, now) when is_binary(token) do
    with :ok <- check_token_size(token),
         {:ok, fields} <- parse_fields(token),
         :ok <- check_skn(fields.skn),
         {:ok, se} <- parse_se(fields.se),
         :ok <- check_expiry(se, now),
         :ok <- check_audience_config(audience_config),
         {:ok, sr} <- check_audience(fields.sr, audience_config),
         :ok <- check_key_size(),
         # string-to-sign uses the URL-ENCODED sr, per the SAS spec (wire-lane
         # fix: signing the decoded sr broke every real-SDK token)
         :ok <- check_signature(URI.decode(fields.sig), fields.sr, se) do
      {:ok, %{sr: sr, sig: fields.sig, se: se, skn: fields.skn, audience: sr}}
    end
  end

  def verify(_token, _audience_config, _now), do: {:error, {400, "UNSUPPORTED_CBS_REQUEST"}}

  # -- parsing ---------------------------------------------------------------

  defp check_token_size(token) do
    if byte_size(token) <= @max_token_bytes, do: :ok, else: {:error, {400, "INVALID_LOCAL_SAS"}}
  end

  # Token body must be exactly the four unique fields sr/sig/se/skn with no
  # extra, duplicate, or malformed entries. Values are URL-decoded on use.
  defp parse_fields(token) do
    case String.split(token, " ", parts: 2) do
      ["SharedAccessSignature", body] ->
        fields =
          body
          |> String.split("&")
          |> Enum.reduce_while(%{}, fn pair, acc ->
            case String.split(pair, "=", parts: 2) do
              [k, v] when k in ["sr", "sig", "se", "skn"] ->
                key = String.to_existing_atom(k)

                if Map.has_key?(acc, key) do
                  {:halt, :duplicate}
                else
                  {:cont, Map.put(acc, key, v)}
                end

              _ ->
                {:halt, :malformed}
            end
          end)

        case fields do
          %{sr: sr, sig: sig, se: se, skn: skn} -> {:ok, %{sr: sr, sig: sig, se: se, skn: skn}}
          _ -> {:error, {400, "INVALID_LOCAL_SAS"}}
        end

      _ ->
        {:error, {400, "INVALID_LOCAL_SAS"}}
    end
  end

  defp check_skn(skn) do
    if skn == @required_skn, do: :ok, else: {:error, {401, "INVALID_LOCAL_SAS"}}
  end

  defp parse_se(se) do
    case Integer.parse(se) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, {400, "INVALID_LOCAL_SAS"}}
    end
  end

  # -- expiry -----------------------------------------------------------------

  # se must be strictly in the future and at most 24h out.
  defp check_expiry(se, now) when se > now and se - now <= @max_token_lifetime, do: :ok
  defp check_expiry(_se, _now), do: {:error, {401, "INVALID_LOCAL_SAS"}}

  # -- audience ---------------------------------------------------------------

  # The configured endpoint/audience itself must be well-formed before it can
  # be used to validate a token audience.
  defp check_audience_config(%Audience{scheme: s, host: h})
       when is_binary(s) and is_binary(h),
       do: :ok

  defp check_audience_config(config) when is_binary(config) do
    case parse_endpoint(config) do
      {:ok, _} -> :ok
      :error -> {:error, {400, "INVALID_LOCAL_AUDIENCE"}}
    end
  end

  defp check_audience_config(_), do: {:error, {400, "INVALID_LOCAL_AUDIENCE"}}

  defp parse_endpoint(config) when is_binary(config) do
    case URI.new(config) do
      {:ok, %URI{scheme: cs, host: ch}} when is_binary(cs) and is_binary(ch) ->
        {:ok, {cs, ch, URI.default_port(cs)}}

      _ ->
        :error
    end
  end

  defp check_audience(raw_sr, audience_config) do
    sr = URI.decode(raw_sr)

    if sr != "" and String.length(sr) <= @max_audience_chars do
      case URI.new(sr) do
        {:ok,
         %URI{scheme: scheme, userinfo: nil, query: nil, fragment: nil, host: host, port: port}}
        when is_binary(scheme) and is_binary(host) ->
          if audience_matches?(scheme, host, port, audience_config) do
            {:ok, sr}
          else
            {:error, {401, "INVALID_LOCAL_SAS"}}
          end

        _ ->
          {:error, {401, "INVALID_LOCAL_SAS"}}
      end
    else
      {:error, {401, "INVALID_LOCAL_SAS"}}
    end
  end

  # A bare `sb:` scheme audience is the Service Bus resource form and is
  # accepted unconditionally.
  defp audience_matches?("sb", _host, _port, _config), do: true

  defp audience_matches?(scheme, host, port, %Audience{scheme: cs, host: ch, port: cp}) do
    scheme == scheme_norm(cs) and String.downcase(host) == String.downcase(ch || "") and
      port_matches?(port, cp)
  end

  defp audience_matches?(scheme, host, port, config) when is_binary(config) do
    case parse_endpoint(config) do
      {:ok, {cs, ch, cp}} ->
        scheme == scheme_norm(cs) and String.downcase(host) == String.downcase(ch) and
          port_matches?(port, cp)

      :error ->
        false
    end
  end

  defp audience_matches?(_scheme, _host, _port, _config), do: false

  defp scheme_norm(nil), do: nil
  defp scheme_norm(scheme), do: scheme

  defp port_matches?(_port, nil), do: true
  defp port_matches?(port, port), do: true
  defp port_matches?(_, _), do: false

  # -- key + signature ---------------------------------------------------------

  defp check_key_size do
    key = shared_key()

    if is_binary(key) and byte_size(key) >= @min_key_bytes do
      :ok
    else
      {:error, {500, "INVALID_LOCAL_SAS"}}
    end
  end

  @doc """
  The Service Bus endpoint used to validate token audiences:
  `Application.get_env(:smalt, :sb_endpoint)`, defaulting to
  `"sb://127.0.0.1:5672"`. Set `:sb_endpoint` to the `sb://`/`amqps://`
  endpoint your clients mint SAS tokens for.
  """
  @spec endpoint() :: String.t()
  def endpoint, do: Application.get_env(:smalt, :sb_endpoint, @default_endpoint)

  @doc """
  The shared key used for HMAC verification: `Application.get_env(:smalt, :sb_shared_key)`
  when set to a binary of at least 32 bytes, otherwise a generated key cached in
  `:persistent_term` for local development.
  """
  @spec shared_key() :: String.t()
  def shared_key do
    case Application.get_env(:smalt, :sb_shared_key) do
      key when is_binary(key) and byte_size(key) >= @min_key_bytes ->
        key

      _ ->
        case :persistent_term.get({__MODULE__, :dev_key}, nil) do
          nil -> generate_dev_key()
          key -> key
        end
    end
  end

  defp generate_dev_key do
    key = Base.encode64(:crypto.strong_rand_bytes(48))
    :persistent_term.put({__MODULE__, :dev_key}, key)
    key
  end

  # sig = Base64(HMAC-SHA256(key, "#{sr}\n#{se}")), compared constant-time.
  defp check_signature(sig, sr, se) do
    case Base.decode64(sig, ignore: :whitespace) do
      {:ok, provided} ->
        expected = :crypto.mac(:hmac, :sha256, shared_key(), "#{sr}\n#{se}")

        if Plug.Crypto.secure_compare(provided, expected) do
          :ok
        else
          {:error, {401, "INVALID_LOCAL_SAS"}}
        end

      :error ->
        {:error, {401, "INVALID_LOCAL_SAS"}}
    end
  end
end
