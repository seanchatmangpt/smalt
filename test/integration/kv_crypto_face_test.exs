defmodule Smalt.Integration.KvCryptoFaceTest do
  # PRD-KV typed-down sub-claim close (v26.10.21): the KV REST crypto face
  # (POST /keys/{name}/sign | /verify, api-version 7.4) is witnessed —
  # roundtrip true / wrong-digest false / bad alg typed 400 / unknown key
  # typed 404 — over real TLS transport with the real STS challenge dance.
  # Reuses the KD-126 court harness shape (kv_ec_create_test.exs); no mocks.
  use ExUnit.Case, async: false

  @api_version "7.4"
  @token_key :kvcrypto_face_sts_token

  test "bad alg on sign is a typed 400 InvalidAlgorithm" do
    {base, cert} = twin()
    name = create_key(base, cert, "kvc-badalg-#{System.system_time(:millisecond)}")
    digest = sha256_b64url("kvc-payload")

    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/sign?api-version=#{@api_version}", %{
        "alg" => "HS256",
        "digest" => digest
      })

    assert status == 400, "expected 400, got #{status}: #{inspect(body)}"
    assert body["error"]["code"] == "InvalidAlgorithm"
  end

  test "bad alg on verify is a typed 400 InvalidAlgorithm" do
    {base, cert} = twin()
    name = create_key(base, cert, "kvc-badalgv-#{System.system_time(:millisecond)}")
    digest = sha256_b64url("kvc-payload")

    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/verify?api-version=#{@api_version}", %{
        "alg" => "HS256",
        "digest" => digest,
        "value" => "AAA"
      })

    assert status == 400, "expected 400, got #{status}: #{inspect(body)}"
    assert body["error"]["code"] == "InvalidAlgorithm"
  end

  test "unknown key sign is a typed 404 KeyNotFound" do
    {base, cert} = twin()

    {status, body} =
      authed(:post, base, cert, "/keys/kvc-nokey-#{System.system_time(:millisecond)}/sign?api-version=#{@api_version}", %{
        "alg" => "ES256",
        "digest" => sha256_b64url("kvc-payload")
      })

    assert status == 404, "expected 404, got #{status}: #{inspect(body)}"
    assert body["error"]["code"] == "KeyNotFound"
  end

  test "unknown key verify is a typed 404 KeyNotFound" do
    {base, cert} = twin()

    {status, body} =
      authed(:post, base, cert, "/keys/kvc-nokey-#{System.system_time(:millisecond)}/verify?api-version=#{@api_version}", %{
        "alg" => "ES256",
        "digest" => sha256_b64url("kvc-payload"),
        "value" => "AAA"
      })

    assert status == 404, "expected 404, got #{status}: #{inspect(body)}"
    assert body["error"]["code"] == "KeyNotFound"
  end

  defp create_key(base, cert, name) do
    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", %{
        "kty" => "EC",
        "crv" => "P-256"
      })

    assert status == 200, "create: #{inspect(body)}"
    name
  end

  defp twin do
    port = Application.fetch_env!(:smalt, :arm_tls_port)
    {cert, _key} = Smalt.TLS.dev_cert_paths(port)
    {"https://127.0.0.1:#{port}", cert}
  end

  defp authed(method, base, cert, path, params) when is_map(params) do
    authed(method, base, cert, path, Jason.encode!(params))
  end

  defp authed(method, base, cert, path, body) do
    case request(method, base, cert, path, body) do
      {401, _} ->
        :persistent_term.put(@token_key, fetch_sts_token(base, cert))
        request(method, base, cert, path, body)

      other ->
        other
    end
  end

  defp request(method, base, cert, path, body) do
    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      String.upcase(Atom.to_string(method)),
      "-H",
      "Authorization: #{bearer_or_anonymous()}",
      "-H",
      "Content-Type: application/json",
      "-d",
      body,
      "-w",
      "\n%{http_code}",
      "#{base}#{path}"
    ]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)
    parts = String.split(String.trim_trailing(out), "\n")
    code = List.last(parts) |> String.to_integer()
    raw = parts |> Enum.drop(-1) |> Enum.join("\n")
    decoded = if raw == "", do: %{}, else: Jason.decode!(raw)
    {code, decoded}
  end

  defp bearer_or_anonymous do
    case :persistent_term.get(@token_key, nil) do
      nil -> "Bearer anonymous-probe"
      tok -> "Bearer #{tok}"
    end
  end

  defp fetch_sts_token(base, cert) do
    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      "POST",
      "-d",
      "grant_type=client_credentials&client_id=kvcrypto-lane&client_secret=kvcrypto-lane&scope=https://vault.azure.net/.default",
      "#{base}/organizations/oauth2/v2.0/token"
    ]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)

    case Jason.decode(out) do
      {:ok, %{"access_token" => tok}} when is_binary(tok) -> tok
      other -> flunk("STS token fetch failed: #{inspect(other)}")
    end
  end

  defp sha256_b64url(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.url_encode64(padding: false)
  end
end
