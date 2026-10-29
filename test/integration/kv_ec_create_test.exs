defmodule Smalt.Integration.KvEcCreateTest do
  # KD-COVERS: KD-126 — Chicago court for the EC arm on the HTTP key-create
  # seam. Real transport (curl subprocess over the test boot's real TLS twin
  # listener), real STS challenge dance, real vault ETS — no mocks.
  #
  # Divergence (pre-fix): POST /keys/:name/create with {"kty":"EC"} answered
  # 400 UnsupportedKeyType while the library seam (KeyVaultActions.create_key/2)
  # supported EC (ES256/ES384, crv/x/y JWK). The fix adds the EC/EC-HSM arm to
  # KvRoutes.jwk_for_kty/4 (crv/x/y public JWK + private DER cached under
  # "key_material" for the sign/verify actions).
  #
  # Auth is disjunctive per the KD-15 corpus premise (same shape as
  # deletedkeys_purge_route_test.exs): tokenless probe first; on 401, real STS
  # dance (POST /{tenant}/oauth2/v2.0/token) and resend bearer.
  use ExUnit.Case, async: false

  @api_version "7.4"
  @token_key :kd126_sts_token

  test "EC create -> ES256 sign -> verify true -> tampered verify false" do
    {base, cert} = twin()
    name = "kd126-#{System.system_time(:millisecond)}"

    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", ~s({"kty":"EC","crv":"P-256"}))

    assert status == 200, "create: #{inspect(body)}"
    key = body["key"]
    assert key["kty"] == "EC"
    assert key["crv"] == "P-256"
    assert is_binary(key["x"]) and is_binary(key["y"])
    assert "sign" in key["key_ops"] and "verify" in key["key_ops"]

    digest = sha256_b64url("kd126-payload")

    {sign_status, sign_body} =
      authed(:post, base, cert, "/keys/#{name}/sign?api-version=#{@api_version}", Jason.encode!(%{"alg" => "ES256", "digest" => digest}))

    assert sign_status == 200
    sig = sign_body["value"]
    assert is_binary(sig) and sig != ""

    {v1_status, v1_body} =
      authed(:post, base, cert, "/keys/#{name}/verify?api-version=#{@api_version}", Jason.encode!(%{"alg" => "ES256", "digest" => digest, "value" => sig}))

    assert v1_status == 200
    assert v1_body["value"] == true
  end

  # KD-126 EC sign seam, live-witnessed 2026-10-20 (W13-C): the pre-fix EC sign
  # arm passed the plug-conn court but :crypto.sign raised
  # {:badarg, _, "Bad binary size for the algorithm"} on a digest-length
  # mismatch (ES384 over a 32-byte digest) -> uncaught ErlangError -> 500.
  # Post-fix: typed 400 InvalidParameter, never a 500.
  test "ES384 over a 32-byte digest answers 400 InvalidParameter, not 500" do
    {base, cert} = twin()
    name = "kd126-es384-#{System.system_time(:millisecond)}"

    {cs, _} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", ~s({"kty":"EC","crv":"P-384"}))

    assert cs == 200

    digest = sha_b64url(:sha256, "kd126-payload")

    {ss, sb} =
      authed(:post, base, cert, "/keys/#{name}/sign?api-version=#{@api_version}", Jason.encode!(%{"alg" => "ES384", "digest" => digest}))

    assert ss == 400, "expected 400, got #{ss}: #{inspect(sb)}"
    assert sb["error"]["code"] == "InvalidParameter"
  end

  test "tampered digest, same signature -> 200 value:false" do
    {base, cert} = twin()
    name = "kd126-tam-#{System.system_time(:millisecond)}"

    {cs, _} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", ~s({"kty":"EC","crv":"P-256"}))

    assert cs == 200
    digest = sha256_b64url("kd126-payload")

    {ss, sb} =
      authed(:post, base, cert, "/keys/#{name}/sign?api-version=#{@api_version}", Jason.encode!(%{"alg" => "ES256", "digest" => digest}))

    assert ss == 200
    sig = sb["value"]
    tampered = sha256_b64url("TAMPERED-kd126")

    {vs, vb} =
      authed(:post, base, cert, "/keys/#{name}/verify?api-version=#{@api_version}", Jason.encode!(%{"alg" => "ES256", "digest" => tampered, "value" => sig}))

    assert vs == 200
    assert vb["value"] == false
  end

  test "P-384 create + ES384 sign round-trip" do
    {base, cert} = twin()
    name = "kd126-p384-#{System.system_time(:millisecond)}"

    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", ~s({"kty":"EC","crv":"P-384"}))

    assert status == 200, "create: #{inspect(body)}"
    assert body["key"]["crv"] == "P-384"

    digest = sha_b64url(:sha384, "kd126-payload")

    {sign_status, sign_body} =
      authed(:post, base, cert, "/keys/#{name}/sign?api-version=#{@api_version}", Jason.encode!(%{"alg" => "ES384", "digest" => digest}))

    assert sign_status == 200
    assert is_binary(sign_body["value"]) and sign_body["value"] != ""
  end

  test "unknown crv is a typed 400 InvalidParameter; RSA/oct creates unchanged" do
    {base, cert} = twin()
    name = "kd126-badcrv-#{System.system_time(:millisecond)}"

    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", ~s({"kty":"EC","crv":"P-999"}))

    assert status == 400
    assert body["error"]["code"] == "InvalidParameter"

    {rsa_status, rsa_body} =
      authed(:post, base, cert, "/keys/kd126-rsa-#{System.system_time(:millisecond)}/create?api-version=#{@api_version}", ~s({"kty":"RSA"}))

    assert rsa_status == 200
    assert is_binary(rsa_body["key"]["n"]) and is_binary(rsa_body["key"]["e"])

    {oct_status, oct_body} =
      authed(:post, base, cert, "/keys/kd126-oct-#{System.system_time(:millisecond)}/create?api-version=#{@api_version}", ~s({"kty":"oct"}))

    assert oct_status == 200
    assert is_binary(oct_body["key"]["k"])
  end

  defp twin do
    port = Application.fetch_env!(:smalt, :arm_tls_port)
    {cert, _key} = Smalt.TLS.dev_cert_paths(port)
    {"https://127.0.0.1:#{port}", cert}
  end

  # One request with bearer reauth on 401: send -> on 401 fetch a fresh STS
  # token, store it, resend. The final status is the answer.
  defp authed(method, base, cert, path, body) do
    case request(method, base, cert, path, body) do
      {401, _} ->
        :persistent_term.put(@token_key, fetch_sts_token(base, cert))
        request(method, base, cert, path, body)

      other ->
        other
    end
  end

  # curl -w appends the http code after the body; split on the LAST newline.
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
      "grant_type=client_credentials&client_id=kd126-lane&client_secret=kd126-lane&scope=https://vault.azure.net/.default",
      "#{base}/organizations/oauth2/v2.0/token"
    ]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)

    case Jason.decode(out) do
      {:ok, %{"access_token" => tok}} when is_binary(tok) -> tok
      other -> flunk("STS token fetch failed: #{inspect(other)}")
    end
  end

  defp sha256_b64url(payload), do: sha_b64url(:sha256, payload)

  defp sha_b64url(md, payload) do
    :crypto.hash(md, payload)
    |> Base.url_encode64(padding: false)
  end
end
