# BK-19 KD-10/KD-75 witness: PUT /keys/{name} (createKey/updateKey face).
#
# Divergence (pre-fix): PUT /keys/:name was unrouted and fell to the blob
# catch-all 400 MissingXMsVersion (KD-10 register row + BK-11 receipt wire
# evidence). Fix: `put "/keys/:name"` in KvRoutes.ex sharing the create arm
# (kv_key_put/3) — real Azure createKey/updateKey share the PUT verb and
# answer 200 KeyBundle.
#
# Chicago discipline: real transport (curl subprocess over the test boot's
# real TLS twin), real STS challenge dance, real vault ETS — no mocks.
#
# Context: solo (integration tier, in-process app boot + real TLS).
defmodule Smalt.Integration.Bk19Kd10KvPutRouteTest do
  use ExUnit.Case, async: false

  @api_version "7.4"
  @token_key :bk19_sts_token

  test "PUT /keys/:name creates (200 + kid), GET reads back, PUT re-put keeps versions" do
    {base, cert} = twin()
    name = "bk19-#{System.system_time(:millisecond)}"

    {status, body} =
      authed(:put, base, cert, "/keys/#{name}?api-version=#{@api_version}", ~s({"kty":"oct","value":"bk19"}))

    assert status == 200, "PUT create: #{inspect(body)}"
    kid = body["key"]["kid"]
    assert is_binary(kid) and String.contains?(kid, "/keys/#{name}/")

    {get_status, get_body} =
      authed(:get, base, cert, "/keys/#{name}?api-version=#{@api_version}", "")

    assert get_status == 200
    assert get_body["key"]["kid"] == kid

    # updateKey face: PUT again — latest record rides the bare name
    {put2_status, _} =
      authed(:put, base, cert, "/keys/#{name}?api-version=#{@api_version}", ~s({"kty":"oct","value":"bk19-v2"}))

    assert put2_status == 200

    {get2_status, get2_body} =
      authed(:get, base, cert, "/keys/#{name}?api-version=#{@api_version}", "")

    assert get2_status == 200
    assert get2_body["key"]["kid"] != kid
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
      "grant_type=client_credentials&client_id=bk19-lane&client_secret=bk19-lane&scope=https://vault.azure.net/.default",
      "#{base}/organizations/oauth2/v2.0/token"
    ]

    {out, 0} = System.cmd("curl", args)
    Jason.decode(out)
    |> case do
      {:ok, %{"access_token" => tok}} when is_binary(tok) -> tok
      other -> flunk("STS token fetch failed: #{inspect(other)}")
    end
  end
end