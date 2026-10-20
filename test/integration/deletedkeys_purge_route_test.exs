# Wave-3 lane w3e (TS wf6 finding): bare `DELETE /deletedkeys/:name` — the
# real Azure KeyClient.purgeDeletedKey wire shape — was unrouted and fell
# through to the blob guarded catch-all (400 MissingXMsVersion). The fix adds
# the route in EgressRouter (dispatch to egress was already correct: the
# `/deletedkeys` prefix was in TlsTwinDispatch.@egress_prefixes).
#
# Chicago discipline: real HTTPS over the real TLS twin listener (Bandit +
# TlsTwinDispatch on the test boot's ephemeral arm_tls_port), real curl
# subprocess transport with --cacert pinned to the listener's actual dev cert
# (no mocks). Asserts on final wire state: delete → 200, purge → 204,
# post-purge get → 404. curl (unlike OTP ssl) accepts a self-signed non-CA
# leaf as a --cacert anchor, matching how the dev twin is driven everywhere
# else (relay-env cheat sheet, bench lanes).
#
# Auth is disjunctive per the KD-15 corpus premise: tokenless probe first —
# anonymous boot passes through (404 KeyNotFound), enforce boot answers 401 →
# real STS challenge dance (POST /{tenant}/oauth2/v2.0/token) and resend
# bearer. This also survives a concurrent async test flipping the global
# :auth_mode mid-run.
defmodule Smalt.Test.Internal.DeletedkeysPurgeRouteTest do
  use ExUnit.Case, async: false

  @api_version "7.4"
  @token_key :w3e_purge_sts_token

  test "purge rides bare DELETE /deletedkeys/:name over the TLS twin (204), post-purge 404" do
    port = Application.fetch_env!(:smalt, :arm_tls_port)
    {cert, _key} = Smalt.TLS.dev_cert_paths(port)
    base = "https://127.0.0.1:#{port}"
    name = "w3e-purge-#{System.system_time(:millisecond)}"

    # 1. create the key (emulator create shape: POST /keys/:name/create)
    create = authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}")

    assert create in 200..201, "create failed: #{create}"

    # 2. soft-delete → 200 DeletedKeyBundle
    assert 200 == authed(:delete, base, cert, "/keys/#{name}?api-version=#{@api_version}")

    # 3. deleted bundle present
    assert 200 == authed(:get, base, cert, "/deletedkeys/#{name}?api-version=#{@api_version}")

    # 4. THE FIX: bare DELETE /deletedkeys/:name → 204 (was 400 MissingXMsVersion
    #    via the blob catch-all before the route landed)
    assert 204 ==
             authed(:delete, base, cert, "/deletedkeys/#{name}?api-version=#{@api_version}")

    # 5. post-purge get → 404 KeyNotFound
    assert 404 ==
             authed(:get, base, cert, "/deletedkeys/#{name}?api-version=#{@api_version}")
  end

  # One request with bearer reauth on 401: send → on 401 fetch a fresh STS
  # token, store it, resend. The final status is the answer.
  defp authed(method, base, cert, path) do
    case request(method, base, cert, path) do
      401 ->
        :persistent_term.put(@token_key, fetch_sts_token(base, cert))
        request(method, base, cert, path)

      status ->
        status
    end
  end

  defp request(method, base, cert, path) do
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
        "-H",
        "Authorization: #{bearer_or_anonymous()}",
        "-H",
        "Content-Type: application/json",
        create_body(path),
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

  defp bearer_or_anonymous do
    case :persistent_term.get(@token_key, nil) do
      nil -> "Bearer anonymous-probe"
      tok -> "Bearer #{tok}"
    end
  end

  # POST /keys/:name/create requires a key material body; other legs carry no
  # body (create_body contributes [] there, flattened away in request/4).
  defp create_body("/keys/" <> _rest = path) do
    if String.contains?(path, "/create") do
      ["--data", ~s({"kty":"oct","key_ops":["encrypt","decrypt"]})]
    else
      []
    end
  end

  defp create_body(_path), do: []

  # Real STS issuer on the twin: POST /{tenant}/oauth2/v2.0/token, any
  # client_id/secret accepted in the emulator's enforce mode (dev substrate
  # contract). Returns the raw access_token string.
  defp fetch_sts_token(base, cert) do
    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      "POST",
      "-d",
      "grant_type=client_credentials&client_id=w3e-lane&client_secret=w3e-lane&scope=https://vault.azure.net/.default",
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
