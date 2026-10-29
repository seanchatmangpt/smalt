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
         :ok <- check_signature(URI.decode(fields.sig), fields.sr, se, fields.skn) do
      {:ok, %{sr: sr, sig: fields.sig, se: se, skn: fields.skn, audience: sr, rights: rights_for_skn(fields.skn)}}
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
    # Namespace key by name, or a queue authorization-rule key
    # (Smalt.Amqp.SbAuthRules — w6am). Unknown skn is still 401.
    if skn == @required_skn or rule_skn?(skn), do: :ok, else: {:error, {401, "INVALID_LOCAL_SAS"}}
  end

  # w6am: rule-derived keys verify with the rule's rights (nil rights on the
  # namespace path keeps the legacy full-access semantics).
  defp rights_for_skn(@required_skn), do: nil

  defp rights_for_skn(skn) do
    case Smalt.Amqp.SbAuthRules.rights_for_skn(skn) do
      {:ok, rights} -> rights
      :error -> nil
    end
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

  # KD-COVERS: KD-172
  # An `sb:`-scheme audience is the Service Bus resource form. SDKs mint it
  # from the connection-string namespace, so the audience host must match the
  # configured endpoint's host (case-insensitive). A loopback endpoint
  # (127.0.0.1/localhost/::1) additionally accepts any loopback audience host,
  # preserving the loopback-only posture without re-opening the foreign-host
  # hole. Foreign `sb://<other-host>` is 401 (INVALID_LOCAL_SAS via
  # check_audience/2).
  defp audience_matches?("sb", host, _port, config) do
    endpoint_host = endpoint_host(config)
    host_eq?(host, endpoint_host) or (loopback_host?(host) and loopback_host?(endpoint_host))
  end

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

  defp endpoint_host(%Audience{host: host}), do: host
  defp endpoint_host(config) when is_binary(config) do
    case parse_endpoint(config) do
      {:ok, {_cs, ch, _cp}} -> ch
      :error -> nil
    end
  end
  defp endpoint_host(_), do: nil

  defp host_eq?(nil, _), do: false
  defp host_eq?(_, nil), do: false
  defp host_eq?(a, b), do: String.downcase(a) == String.downcase(b)

  # BK-AMPSKEP F1 repair: the previous `String.starts_with?(h, "127.")`
  # prefix-match accepted attacker-resolvable domains like `127.evil.example`.
  # Loopback IPv4 is now an IP-literal check via :inet.parse_address — only
  # dotted-quad literals in 127/8 parse as {127,_,_,_}; hostnames with a "127."
  # prefix refuse typed 401. localhost/[::1]/::1 stay exact (case-insensitive).
  defp loopback_host?(host) when is_binary(host) do
    h = String.downcase(host)
    h == "localhost" or h == "::1" or h == "[::1]" or loopback_ipv4?(h)
  end

  defp loopback_host?(_), do: false

  defp loopback_ipv4?(h) do
    case :inet.parse_address(String.to_charlist(h)) do
      {:ok, {127, _, _, _}} -> true
      _ -> false
    end
  end

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
  when set to a binary of at least 32 bytes; otherwise the deterministic dev
  key `base64(sha256(short_hostname <> "smalt-dev-sb"))` (44 bytes, identical to
  `scripts/dev_env.sh` / `scripts/substrate.sh`), cached in `:persistent_term`.
  A configured key below the #{@min_key_bytes}-byte floor is refused at boot by
  `validate_boot_key!/0` — it is never silently replaced here.
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

  @doc """
  Boot guard: refuse a configured `:sb_shared_key` below the #{@min_key_bytes}-byte
  floor with a typed error (raised, so boot fails loudly instead of clients
  hitting 401 INVALID_LOCAL_SAS against an unverifiable key). `nil` and
  >=#{@min_key_bytes}-byte keys pass.
  """
  @spec validate_boot_key!() :: :ok
  def validate_boot_key! do
    case Application.get_env(:smalt, :sb_shared_key) do
      key when is_binary(key) and byte_size(key) >= @min_key_bytes -> :ok
      nil -> :ok
      other -> raise ArgumentError, message: "invalid :sb_shared_key (#{inspect(other)}): must be nil or at least #{@min_key_bytes} bytes"
    end
  end

  # Deterministic dev key: same derivation shape as scripts/dev_env.sh —
  # base64(sha256(short_hostname <> "smalt-dev-sb")), 44 chars >= @min_key_bytes.
  # Determinism is the fix for M4: a boot without an explicit :sb_shared_key
  # now yields the same key dev clients derive, so CBS SAS signing works
  # against a plain dev boot instead of 401 INVALID_LOCAL_SAS.
  # KD-S5/KD-W01: the host is normalized to its short form (domain stripped
  # at the first ".") on BOTH sides — this module and the shell scripts — so
  # `hostname` vs `hostname -s` variance (e.g. "Mac.lan" vs "Mac") can no
  # longer split producer and verifier onto different keys.
  defp generate_dev_key do
    key = dev_shared_key()
    :persistent_term.put({__MODULE__, :dev_key}, key)
    key
  end

  @doc """
  The canonical per-host dev key: `base64(sha256(short_hostname <>
  "smalt-dev-sb"))` — the single derivation consumed by the SAS verifier
  fallback (`shared_key/0`) and pinned by test/integration/dev_shared_key_
  derivation_test.exs. The host is normalized to its short form (text before
  the first "."), matching `hostname -s`, so FQDN vs short-hostname variance
  cannot desynchronize producer and verifier.
  """
  @spec dev_shared_key() :: String.t()
  def dev_shared_key do
    {:ok, hostname} = :inet.gethostname()
    host = normalize_host(to_string(hostname))
    Base.encode64(:crypto.hash(:sha256, host <> "smalt-dev-sb"))
  end

  # Normalize the local hostname to its short form: everything before the
  # first "." ("Mac.lan" -> "Mac"). A bare short hostname is returned as-is.
  defp normalize_host(host) when is_binary(host) do
    case String.split(host, ".", parts: 2) do
      [short | _] -> short
    end
  end

  # sig = Base64(HMAC-SHA256(key, "#{sr}\n#{se}")), compared constant-time.
  # w6am: non-namespace skn verifies against the rule's primary then secondary
  # key (SbAuthRules.lookup_by_name), each compared constant-time.
  defp check_signature(sig, sr, se, @required_skn) do
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

  defp check_signature(sig, sr, se, skn) do
    case Base.decode64(sig, ignore: :whitespace) do
      {:ok, provided} ->
        verify_rule_signature(provided, sr, se, skn)

      :error ->
        {:error, {401, "INVALID_LOCAL_SAS"}}
    end
  end

  defp verify_rule_signature(provided, sr, se, skn) do
    rules =
      try do
        Smalt.Amqp.SbAuthRules.rules_for_skn(skn)
      rescue
        _ -> []
      end

    candidate_keys =
      Enum.flat_map(rules, fn rule -> [rule.primary_key, rule.secondary_key] end)

    if candidate_keys != [] do
      expected_sigs =
        Enum.map(candidate_keys, fn key -> :crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}") end)

      if Enum.any?(expected_sigs, fn expected -> Plug.Crypto.secure_compare(provided, expected) end) do
        :ok
      else
        {:error, {401, "INVALID_LOCAL_SAS"}}
      end
    else
      {:error, {401, "INVALID_LOCAL_SAS"}}
    end
  end

  defp rule_skn?(skn) do
    try do
      Smalt.Amqp.SbAuthRules.skn_exists?(skn)
    rescue
      _ -> false
    end
  end
end
