# COSMOS404 lane (v26.10.20): witnessed defect (T1/T14, 2026-10-21, disclosure
# in tmp/bench/scvd_tier1.mjs:46-48) — GET /dbs/<nonexistent> answered 500 on
# the live substrate, crashing @azure/cosmos createIfNotExists' read-first.
# At HEAD (934d21a) the missing-database arm answers the typed 404; the
# witnessed 500 was the same blob_error/3 BadBooleanError class KV404 fenced
# (ad3136b) firing on the cosmos face. This test fences the regression on the
# wire so the arm cannot rot back.
#
# Chicago discipline: real HTTPS over the real twin listener (Bandit +
# Smalt.Application.TlsTwinDispatch on the test boot's ephemeral arm_tls_port;
# "/dbs/" is an egress prefix on the twin seat), real curl subprocess
# transport, asserting final wire state (status + body face). A seeded
# database proves the 200 leg is this route, not an accidental miss.
defmodule Smalt.Test.Internal.Cosmos404TypedErrorTest do
  use ExUnit.Case, async: false

  @token_key :cosmos404_sts_token

  test "GET on a missing database answers 404 NotFound JSON, not 500" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    present = "cosmos404-present-#{ts}"
    absent = "cosmos404-absent-#{ts}"

    # Seed a real database so the 200 leg proves the route is live (and that
    # the 404 leg is a true miss, not a misroute to some other 404 face).
    assert {201, created} =
             authed(:post, base, cert, "/dbs", Jason.encode!(%{"id" => present}), [
               "Content-Type: application/json"
             ])

    assert created =~ present

    assert {200, got} = authed_body(:get, base, cert, "/dbs/#{present}")
    assert got =~ present

    # The witnessed defect: GET missing answered 500. Documented face:
    # 404 + {"code":"NotFound",...} — the envelope @azure/cosmos surfaces.
    {status, body} = authed_body(:get, base, cert, "/dbs/#{absent}")
    assert status == 404
    assert body =~ "NotFound"
    assert body =~ absent

    # Same face for the SDK's fallback probe: GET the database feed is fine;
    # a second read of the absent db stays 404 (idempotent, no 500).
    assert {404, body2} = authed_body(:get, base, cert, "/dbs/#{absent}")
    assert body2 =~ "NotFound"
  end

  # One request with bearer reauth on 401: send → on 401 fetch a fresh STS
  # token, store it, resend. The final status is the answer (KD-15 challenge
  # dance, disjunctive: anonymous boot passes through tokenless).
  defp authed(method, base, cert, path, body, extra_headers) do
    case request_body(method, base, cert, path, body, extra_headers) do
      {401, _} ->
        :persistent_term.put(@token_key, fetch_sts_token(base, cert))
        request_body(method, base, cert, path, body, extra_headers)

      other ->
        other
    end
  end

  defp authed_body(method, base, cert, path) do
    authed(method, base, cert, path, nil, ["x-ms-version: 2018-12-31"])
  end

  defp request_body(method, base, cert, path, body, extra_headers) do
    args =
      List.flatten([
        "-s",
        "--cacert",
        cert,
        "-w",
        "\n%{http_code}",
        "-X",
        String.upcase(Atom.to_string(method)),
        header_args(extra_headers),
        auth_header(),
        body_args(body),
        "#{base}#{path}"
      ])

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)

    case String.trim_trailing(out) |> String.split("\n") |> List.last() |> Integer.parse() do
      {code, ""} when code in 100..599 ->
        body = out |> String.split("\n") |> Enum.drop(-1) |> Enum.join("\n")
        {code, body}

      _ ->
        raise "curl returned non-status output for #{path}: #{inspect(out)}"
    end
  end

  defp twin do
    port = Application.fetch_env!(:smalt, :arm_tls_port)
    {cert, _key} = Smalt.TLS.dev_cert_paths(port)
    {"https://127.0.0.1:#{port}", cert}
  end

  defp header_args(headers), do: Enum.flat_map(headers, &["-H", &1])

  defp auth_header do
    case :persistent_term.get(@token_key, nil) do
      nil -> ["-H", "Authorization: Bearer anonymous-probe"]
      tok -> ["-H", "Authorization: Bearer #{tok}"]
    end
  end

  defp body_args(nil), do: []
  defp body_args(body), do: ["--data-binary", body]

  # Real STS issuer on the twin: POST /{tenant}/oauth2/v2.0/token (dev
  # substrate contract: any client_id/secret accepted in enforce mode).
  defp fetch_sts_token(base, cert) do
    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      "POST",
      "-d",
      "grant_type=client_credentials&client_id=cosmos404-lane&client_secret=cosmos404-lane&scope=https://documents.azure.com/.default",
      "#{base}/organizations/oauth2/v2.0/token"
    ]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)

    case Jason.decode(out) do
      {:ok, %{"access_token" => tok}} when is_binary(tok) ->
        tok

      other ->
        flunk("STS token fetch failed: #{inspect(other)}")
    end
  end
end
