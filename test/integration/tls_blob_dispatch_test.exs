# W13-D lane (v26.10.20): the TLS twin dispatch flip (KD-114) routes the
# storage catch-all family (blob /{account}/{container}/{blob}, queue plane,
# Files plane — arbitrary account-shaped paths, no enumerable prefix) to
# EgressRouter on https://127.0.0.1:{arm_tls_port}, same handler engine as
# http 8443. Chicago discipline: real HTTPS over the real twin listener
# (Bandit + TlsTwinDispatch on the test boot's ephemeral arm_tls_port), real
# curl subprocess transport with --cacert pinned to the listener's actual dev
# cert (no mocks), asserting final wire state.
#
# KD-35 posture: bearer-bearing planes ride the twin — KV/ARM already did;
# this leg witnesses the storage face with the same challenge dance. The
# SharedKey-admit leg (real-SDK SAS over the twin) stays registered HEAVY in
# KD-114's falsifier; the bearer leg witnesses the dispatch, not SAS admit.
defmodule Smalt.Test.Internal.TlsBlobDispatchTest do
  use ExUnit.Case, async: false

  @blob_version "2023-11-03"
  @token_key :w13d_twin_sts_token

  test "blob PUT/GET ride the TLS twin through the flipped dispatch (201/200, byte-equal)" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    path = "/w13dlane/cont-#{ts}/blob-#{ts}.txt"
    body = "w13d kd114 twin witness #{ts}"

    # Create the container first (real Azure: PUT blob into a missing
    # container is 404 ContainerNotFound — same here).
    assert 201 ==
             authed(:put, base, cert, "/w13dlane/cont-#{ts}", nil, [
               "x-ms-version: #{@blob_version}"
             ])

    assert 201 ==
             authed(:put, base, cert, path, body, [
               "x-ms-blob-type: BlockBlob",
               "x-ms-version: #{@blob_version}"
             ])

    assert {200, ^body} =
             authed_body(:get, base, cert, path, ["x-ms-version: #{@blob_version}"])

    # Storage 404 stays storage-shaped (typed blob XML error, not ARM JSON).
    assert {404, missing} =
             authed_body(:get, base, cert, "/w13dlane/cont-#{ts}/absent.txt", [
               "x-ms-version: #{@blob_version}"
             ])

    assert missing =~ "BlobNotFound"
  end

  test "ARM surface stays ARM-routed on the twin (dispatch control legs)" do
    {base, cert} = twin()

    # /subscriptions-scoped ARM route stays ARM-shaped on the twin (the
    # emulator answers the fixed dev subscription with its metadata 200).
    assert {200, sub} =
             authed_body(
               :get,
               base,
               cert,
               "/subscriptions/00000000-0000-0000-0000-000000000000?api-version=2022-09-01",
               []
             )

    assert sub =~ "Sovereign Smalt Subscription"

    # Identity STS on the twin (ARM-owned oauth2 branch of the dispatch cond).
    {sts_out, 0} =
      System.cmd("curl", [
        "-s",
        "--cacert",
        cert,
        "-X",
        "POST",
        "-d",
        "grant_type=client_credentials&client_id=w13d-lane&client_secret=w13d-lane&scope=https://vault.azure.net/.default",
        "#{base}/organizations/oauth2/v2.0/token"
      ])

    assert %{"access_token" => tok} = Jason.decode!(sts_out)
    assert is_binary(tok) and byte_size(tok) > 0
  end

  # One request with bearer reauth on 401: send → on 401 fetch a fresh STS
  # token, store it, resend. The final status is the answer (KD-15 challenge
  # dance, disjunctive: anonymous boot passes through tokenless).
  defp authed(method, base, cert, path, body, extra_headers) do
    case request(method, base, cert, path, body, extra_headers) do
      401 ->
        :persistent_term.put(@token_key, fetch_sts_token(base, cert))
        request(method, base, cert, path, body, extra_headers)

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

  defp request(method, base, cert, path, body, extra_headers) do
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
        header_args(extra_headers),
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
      "grant_type=client_credentials&client_id=w13d-lane&client_secret=w13d-lane&scope=https://vault.azure.net/.default",
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
