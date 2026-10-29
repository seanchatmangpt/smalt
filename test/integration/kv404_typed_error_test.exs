# KV404 lane (v26.10.20): witnessed defect — GET on a missing KV row returned
# an empty HTTP 500 instead of the documented 404 KvNotFound. Root cause: the
# blob-face guard inside EgressRouter.blob_error/3 evaluated
# `conn.private[:smalt_blob_face] and is_binary(code)`; on the KV face the
# private key is nil and `nil and _` raised BadBooleanError, which Plug
# converted to an empty 500. Fixed by the short-circuit `&&` (ad3136b); this
# test fences the regression on the wire.
#
# Chicago discipline: real HTTPS over the real twin listener (Bandit +
# TlsTwinDispatch on the test boot's ephemeral arm_tls_port), real curl
# subprocess transport, asserting final wire state (status + body face).
defmodule Smalt.Test.Internal.Kv404TypedErrorTest do
  use ExUnit.Case, async: false

  @token_key :kv404_sts_token

  test "GET/DELETE on a missing kv answers 404 KvNotFound JSON, not 500" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    present = "kv404-present-#{ts}"
    absent = "kv404-absent-#{ts}"

    # Seed a real row so the 200 leg proves the route is live, not routed
    # somewhere else that happens to answer 404.
    # D6/KD-LITH-WIRE-3 2026-10-25: /kv PUT answers the documented real-Azure
    # contract — 201 on first create, 200 on update.
    assert 201 == authed(:put, base, cert, "/kv/#{present}", Jason.encode!(%{"value" => "v1"}))

    assert {200, got} = authed_body(:get, base, cert, "/kv/#{present}", [])
    assert got =~ present

    # The witnessed defect: GET missing returned an EMPTY 500 (BadBooleanError
    # in blob_error/3). Documented face: 404 + typed JSON KvNotFound.
    {status, body} = authed_body(:get, base, cert, "/kv/#{absent}", [])
    assert status == 404
    assert body =~ "KvNotFound"

    assert {404, del_body} = authed_body(:delete, base, cert, "/kv/#{absent}", [])
    assert del_body =~ "KvNotFound"
  end

  test "missing dotted appconfig key (%2F-encoded) answers 404 KvNotFound" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)

    # The exact witnessed wire shape: .appconfig.key/<missing> with the slash
    # percent-encoded — Plug route param decodes %2F inside the :key segment.
    {status, body} =
      authed_body(:get, base, cert, "/kv/.appconfig.key%2Fkv404-missing-#{ts}", [])

    assert status == 404
    assert body =~ "KvNotFound"
  end

  # One request with bearer reauth on 401: send → on 401 fetch a fresh STS
  # token, store it, resend. The final status is the answer (KD-15 challenge
  # dance, disjunctive: anonymous boot passes through tokenless).
  defp authed(method, base, cert, path, body) do
    case request(method, base, cert, path, body) do
      401 ->
        :persistent_term.put(@token_key, fetch_sts_token(base, cert))
        request(method, base, cert, path, body)

      status ->
        status
    end
  end

  defp authed_body(method, base, cert, path, extra_headers) do
    case request_body(method, base, cert, path, nil, extra_headers) do
      {401, _} ->
        :persistent_term.put(@token_key, fetch_sts_token(base, cert))
        request_body(method, base, cert, path, nil, extra_headers)

      other ->
        other
    end
  end

  defp request(method, base, cert, path, body) do
    args =
      List.flatten([
        "-s",
        "--cacert",
        cert,
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "-X",
        String.upcase(Atom.to_string(method)),
        auth_header(),
        body_args(body),
        "#{base}#{path}"
      ])

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)

    case Integer.parse(String.trim(out)) do
      {code, ""} when code in 100..599 ->
        code

      _ ->
        raise "curl returned non-status output for #{path}: #{inspect(out)}"
    end
  end

  # Status + body: status is captured via -w on a trailing line, split off
  # below (the body itself may be empty).
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
      "grant_type=client_credentials&client_id=kv404-lane&client_secret=kv404-lane&scope=https://appconfig.io/.default",
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
