defmodule Smalt.Amqp.SasVerifierTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.SasVerifier

  @key Base.encode64(:crypto.strong_rand_bytes(48))
  @now 1_700_000_000

  setup do
    Application.put_env(:smalt, :sb_shared_key, @key)
    on_exit(fn -> Application.delete_env(:smalt, :sb_shared_key) end)
    :ok
  end

  defp sign(sr, se) do
    @key
    |> then(&:crypto.mac(:hmac, :sha256, &1, "#{sr}\n#{se}"))
    |> Base.encode64()
    |> URI.encode_www_form()
  end

  defp token(sr, se_or_opts \\ [], opts \\ []) do
    {se, opts} =
      case se_or_opts do
        se when is_integer(se) -> {se, opts}
        o when is_list(o) -> {@now + 600, o}
      end

    skn = Keyword.get(opts, :skn, "RootManageSharedAccessKey")
    # String-to-sign is the URL-ENCODED sr, exactly as it appears in the token
    # (SAS spec / real-SDK form; see SasVerifier.check_signature/3).
    sig = Keyword.get(opts, :sig, sign(sr, se))
    fields = Keyword.get(opts, :fields, "sr=#{sr}&sig=#{sig}&se=#{se}&skn=#{skn}")
    "SharedAccessSignature " <> fields
  end

  defp sb_url, do: "sb://smalt.example.com/queues/orders"
  defp enc(url), do: URI.encode_www_form(url)

  defp endpoint_config do
    %SasVerifier.Audience{scheme: "https", host: "smalt.example.com", port: 5671}
  end

  test "valid token round-trips with matching endpoint config" do
    sr = enc("https://smalt.example.com:5671/queues/orders")

    assert {:ok, claims} = SasVerifier.verify(token(sr), endpoint_config(), @now)
    assert claims.se == @now + 600
    assert claims.skn == "RootManageSharedAccessKey"
    assert claims.audience == "https://smalt.example.com:5671/queues/orders"
    assert is_binary(claims.sig)
  end

  test "valid token with bare sb scheme audience" do
    assert {:ok, claims} = SasVerifier.verify(token(enc(sb_url())), endpoint_config(), @now)
    assert claims.audience == sb_url()
  end

  test "valid token when audience config is a string endpoint" do
    assert {:ok, _claims} =
             SasVerifier.verify(token(enc("amqps://other.host:5671/q")), "amqps://other.host:5671", @now)
  end

  test "wrong signature is rejected" do
    bad_sig = Base.encode64(:crypto.strong_rand_bytes(32)) |> URI.encode_www_form()

    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc(sb_url()), sig: bad_sig), endpoint_config(), @now)
  end

  test "signature computed over the wrong sr is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(
               token(enc(sb_url()), sig: sign("sb://other/queue", @now + 600)),
               endpoint_config(),
               @now
             )
  end

  test "signature computed over decoded sr is rejected (URL-encoded sr required for string-to-sign)" do
    raw_url = "https://smalt.example.com:5671/queues/orders"
    enc_sr = enc(raw_url)
    # HMAC signature computed over decoded sr instead of encoded sr
    sig_over_decoded = sign(raw_url, @now + 600)

    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(
               token(enc_sr, sig: sig_over_decoded),
               endpoint_config(),
               @now
             )
  end

  test "expired se is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc(sb_url()), @now), endpoint_config(), @now)
  end

  test "se more than 86400 seconds out is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc(sb_url()), @now + 86_401), endpoint_config(), @now)
  end

  test "se exactly 86400 seconds out is accepted" do
    assert {:ok, _} = SasVerifier.verify(token(enc(sb_url()), @now + 86_400), endpoint_config(), @now)
  end

  test "non-integer se is rejected" do
    fields = "sr=#{enc(sb_url())}&sig=#{sign(sb_url(), @now + 600)}&se=abc&skn=RootManageSharedAccessKey"

    assert {:error, {400, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify("SharedAccessSignature " <> fields, endpoint_config(), @now)
  end

  test "missing field is rejected" do
    se = @now + 600
    body = "sr=#{enc(sb_url())}&se=#{se}&skn=RootManageSharedAccessKey"

    assert {:error, {400, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify("SharedAccessSignature " <> body, endpoint_config(), @now)
  end

  test "duplicate field is rejected" do
    se = @now + 600
    body = "sr=#{enc(sb_url())}&sr=#{enc(sb_url())}&sig=#{sign(sb_url(), se)}&se=#{se}&skn=RootManageSharedAccessKey"

    assert {:error, {400, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify("SharedAccessSignature " <> body, endpoint_config(), @now)
  end

  test "appended extra field is rejected" do
    se = @now + 600
    body = "sr=#{enc(sb_url())}&sig=#{sign(sb_url(), se)}&se=#{se}&skn=RootManageSharedAccessKey&ver=1"

    assert {:error, {400, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify("SharedAccessSignature " <> body, endpoint_config(), @now)
  end

  test "malformed pair without = is rejected" do
    se = @now + 600
    body = "sr=#{enc(sb_url())}&sig&se=#{se}&skn=RootManageSharedAccessKey"

    assert {:error, {400, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify("SharedAccessSignature " <> body, endpoint_config(), @now)
  end

  test "missing SharedAccessSignature prefix is rejected" do
    se = @now + 600

    assert {:error, {400, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(
               "sr=#{enc(sb_url())}&sig=x&se=#{se}&skn=RootManageSharedAccessKey",
               endpoint_config(),
               @now
             )
  end

  test "token over 8192 bytes is rejected" do
    pad = String.duplicate("A", 9_000)

    assert {:error, {400, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc(sb_url())) <> pad, endpoint_config(), @now)
  end

  test "wrong skn is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc(sb_url()), skn: "SendOnly"), endpoint_config(), @now)
  end

  test "audience host mismatch is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc("https://evil.example.com:5671/q")), endpoint_config(), @now)
  end

  test "audience scheme mismatch is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc("ftp://smalt.example.com:5671/q")), endpoint_config(), @now)
  end

  test "audience port mismatch is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc("https://smalt.example.com:9999/q")), endpoint_config(), @now)
  end

  test "audience with query is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc(sb_url() <> "?api-version=2021")), endpoint_config(), @now)
  end

  test "audience with userinfo is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc("https://alice@smalt.example.com:5671/q")), endpoint_config(), @now)
  end

  test "audience with fragment is rejected" do
    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc(sb_url() <> "#frag")), endpoint_config(), @now)
  end

  test "audience over 1024 chars is rejected" do
    long = "sb://x/" <> String.duplicate("q", 1100)

    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc(long)), endpoint_config(), @now)
  end

  test "non-binary token is rejected as unsupported" do
    assert {:error, {400, "UNSUPPORTED_CBS_REQUEST"}} =
             SasVerifier.verify(42, endpoint_config(), @now)
  end

  test "dev fallback key is generated, cached, and at least 32 bytes" do
    Application.delete_env(:smalt, :sb_shared_key)

    k1 = SasVerifier.shared_key()
    k2 = SasVerifier.shared_key()
    assert byte_size(k1) >= 32
    assert k1 == k2
  end

  # -- config-driven endpoint --------------------------------------------------

  test "verify/1 honors the configured :sb_endpoint" do
    Application.put_env(:smalt, :sb_endpoint, "amqps://other.host:5671")
    on_exit(fn -> Application.delete_env(:smalt, :sb_endpoint) end)

    sr = enc("amqps://other.host:5671/q")
    assert {:ok, claims} = SasVerifier.verify(token(sr, System.system_time(:second) + 600))
    assert claims.audience == "amqps://other.host:5671/q"
  end

  test "verify/1 rejects a token audience foreign to the configured endpoint" do
    Application.put_env(:smalt, :sb_endpoint, "amqps://other.host:5671")
    on_exit(fn -> Application.delete_env(:smalt, :sb_endpoint) end)

    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(
               token(enc("https://smalt.example.com:5671/q"), System.system_time(:second) + 600)
             )
  end

  test "malformed configured endpoint yields INVALID_LOCAL_AUDIENCE" do
    Application.put_env(:smalt, :sb_endpoint, ":::not a url")
    on_exit(fn -> Application.delete_env(:smalt, :sb_endpoint) end)

    assert {:error, {400, "INVALID_LOCAL_AUDIENCE"}} =
             SasVerifier.verify(token(enc(sb_url()), System.system_time(:second) + 600))
  end

  test "endpoint/0 defaults to the local emulator endpoint" do
    Application.delete_env(:smalt, :sb_endpoint)
    assert SasVerifier.endpoint() == "sb://127.0.0.1:5672"
  end

  test "malformed explicit string endpoint config yields INVALID_LOCAL_AUDIENCE" do
    assert {:error, {400, "INVALID_LOCAL_AUDIENCE"}} =
             SasVerifier.verify(token(enc(sb_url())), "not a url", @now)
  end

  test "shared_key fallback is stable across calls within one config" do
    k1 = SasVerifier.shared_key()
    k2 = SasVerifier.shared_key()
    assert k1 == k2
  end

  test "back-compat: 2-arity verify with explicit audience config unchanged" do
    assert {:ok, claims} =
             SasVerifier.verify(token(enc(sb_url()), System.system_time(:second) + 600), endpoint_config())
    assert is_integer(claims.se)

    assert {:error, {401, "INVALID_LOCAL_SAS"}} =
             SasVerifier.verify(token(enc("https://evil.example.com:5671/q")), endpoint_config())
  end
end
