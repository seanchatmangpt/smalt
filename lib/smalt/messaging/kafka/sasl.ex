defmodule Smalt.Messaging.Kafka.Sasl do
  @moduledoc """
  AZ-1 — Kafka SASL admission kernel (pure module, no socket ownership).

  Config posture (default-off): with no `config :smalt, kafka: [...]`
  entry the face is byte-identical to the pre-SASL surface —
  `required?/0` is false, every connection boots in phase `:open`.

  Config read site (raw Application reads by law — `lib/smalt/config.ex`
  is GENERATED, never hand-edited):

  - `config :smalt, kafka: [sasl_required: true, sasl_mechanisms: [:plain]]`
    → every new connection boots in phase `:await_sasl` and only
    SaslHandshake (17) / SaslAuthenticate (36) / ApiVersions (18) are
    routable until authentication succeeds.

  Mechanisms: `:plain` (RFC 4616 — non-blank authcid + password, dev-STS
  posture: any non-blank credential pair is admitted, blank is refused
  `{:refused, :invalid_client}`); `:anonymous` admitted only when
  configured AND `Smalt.Config.auth_mode()` is not `:enforce`.

  Named falsifier: an UNADVERTISED mechanism on SaslHandshake must answer
  error 33 (UNSUPPORTED_SASL_MECHANISM) followed by a connection kill —
  never a parse guess of an unconfigured mechanism.
  """

  alias Smalt.Config

  @type plain_creds :: {:ok, binary(), binary(), binary()} | {:error, :malformed_plain}

  @doc "Configured SASL mechanisms (atoms); default [:plain] (default-off posture)."
  @spec mechanisms() :: [atom()]
  def mechanisms do
    Application.get_env(:smalt, :kafka, [])[:sasl_mechanisms] || [:plain]
  end

  @doc "SASL-required posture — false default keeps the face byte-identical."
  @spec required?() :: boolean()
  def required? do
    Application.get_env(:smalt, :kafka, [])[:sasl_required] == true
  end

  @doc "Wire mechanism name for a configured mechanism atom."
  @spec wire_name(atom()) :: String.t()
  def wire_name(:plain), do: "PLAIN"
  def wire_name(:anonymous), do: "ANONYMOUS"

  @doc """
  RFC 4616 SASL PLAIN auth message: one i32 length prefix over
  `authzid <<0>> authcid <<0>> password`. Exactly three nul-separated
  fields; a shape violation is `{:error, :malformed_plain}` (crash-only,
  never a best-effort guess).
  """
  @spec parse_plain(binary()) :: plain_creds()
  def parse_plain(
        <<len::unsigned-integer-size(32), blob::binary-size(len)-unit(8)>> = auth_bytes
      )
      when byte_size(auth_bytes) == len + 4 do
    case :binary.split(blob, <<0>>, [:global]) do
      [authzid, authcid, password] ->
        {:ok, authzid, authcid, password}

      _ ->
        {:error, :malformed_plain}
    end
  end

  def parse_plain(_), do: {:error, :malformed_plain}

  @doc """
  Admit or refuse one mechanism/credential pair. `:ok`-class returns are
  `{:ok, principal}`; refusals are typed `{:refused, reason}`.
  """
  @spec authenticate(atom(), term()) :: {:ok, term()} | {:refused, atom()} | {:error, :malformed_plain}
  def authenticate(:plain, {:ok, _authzid, authcid, password}) do
    if blank?(authcid) or blank?(password) do
      {:refused, :invalid_client}
    else
      {:ok, authcid}
    end
  end

  def authenticate(:plain, {:error, :malformed_plain}), do: {:error, :malformed_plain}

  def authenticate(:anonymous, _token) do
    cond do
      :anonymous not in mechanisms() -> {:refused, :anonymous_not_configured}
      Config.auth_mode() == :enforce -> {:refused, :anonymous_under_enforce}
      true -> {:ok, :anonymous}
    end
  end

  def authenticate(_mechanism, _creds), do: {:refused, :unsupported_mechanism}

  defp blank?(b) when is_binary(b), do: b == ""
  defp blank?(nil), do: true
end
