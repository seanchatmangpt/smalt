defmodule Smalt.Identity.OidcAuthorizeTest do
  @moduledoc """
  T05 lane L18: real-server integration court for the /authorize + consent
  leg and the rotating refresh-token law. Real Bandit HTTP server, real HTTP
  over Finch, real RSA verification against the JWKS-served key, real form
  parse + submit (browser-equivalent), real 302 to the client callback. No
  mocks, no sleeps — readiness is synchronous (Thousand Island binds its
  listener before Bandit's start_link returns).
  """

  use ExUnit.Case, async: false

  alias Smalt.Identity.OidcAuthorize
  alias Smalt.Identity.OidcCodeStore

  @redirect "http://localhost:3000/callback"

  setup_all do
    port = start_server()
    {:ok, %{port: port}}
  end

  defp start_server(attempt \\ 1)

  defp start_server(attempt) when attempt > 5 do
    raise "no free port after 5 attempts"
  end

  defp start_server(attempt) do
    port = 51_700 + :rand.uniform(2_000)

    case bandit_up?(port) do
      true ->
        start_server(attempt + 1)

      false ->
        Application.put_env(:smalt, :oidc_port, port)

        case Supervisor.start_link([{Finch, name: L18Finch}, {Smalt.Identity.OidcIdp, port: port}],
               strategy: :one_for_one,
               name: L18OidcTestSup
             ) do
          {:ok, sup} ->
            on_exit(fn ->
              Supervisor.stop(sup)
              Application.delete_env(:smalt, :oidc_idp)
            end)

            port
        end
    end
  end

  defp bandit_up?(port) do
    case :gen_tcp.listen(port, []) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        false

      {:error, :eaddrinuse} ->
        true

      {:error, _other} ->
        false
    end
  end

  defp base, do: "http://127.0.0.1:" <> Integer.to_string(Application.get_env(:smalt, :oidc_port))

  defp get(path) do
    {:ok, resp} = Finch.request(Finch.build(:get, base() <> path), L18Finch)
    resp
  end

  defp post_form(path, form) do
    req =
      Finch.build(:post, base() <> path, [{"content-type", "application/x-www-form-urlencoded"}],
        URI.encode_query(form)
      )

    {:ok, resp} = Finch.request(req, L18Finch)
    resp
  end

  defp post_token(form), do: post_form("/organizations/oauth2/v2.0/token", form)

  defp authorize_params(overrides) do
    %{
      "client_id" => "l18-client",
      "redirect_uri" => @redirect,
      "response_type" => "code",
      "scope" => "openid profile email",
      "code_challenge" => "cch-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
      "code_challenge_method" => "S256",
      "nonce" => "l18-nonce-" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false),
      "state" => "l18-state-" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp get_authorize(overrides \\ %{}) do
    get("/organizations/authorize?" <> URI.encode_query(authorize_params(overrides)))
  end

  # Browser-equivalent: parse the served consent form (action + hidden
  # inputs), then submit exactly what the form would submit.
  defp parse_form(html) do
    [_, action] = Regex.run(~r/<form method="POST" action="([^"]+)">/, html)

    fields =
      Regex.scan(~r/<input type="hidden" name="([^"]+)" value="([^"]*)"/, html)
      |> Enum.map(fn [_all, k, v] -> {k, v} end)
      |> Map.new()

    %{action: action, fields: fields}
  end

  # Full consent flow: GET the form, submit its exact fields, return
  # {code, state} from the 302 Location.
  defp consent_code(overrides \\ %{}) do
    resp = get_authorize(overrides)

    assert resp.status == 200,
           "authorize GET failed: #{resp.status} #{inspect(String.slice(resp.body, 0, 200))}"

    %{fields: fields} = parse_form(resp.body)

    redirected = post_form("/organizations/authorize", fields)

    assert redirected.status == 302, "consent POST failed: #{redirected.status} #{redirected.body}"

    {"location", location} =
      Enum.find(redirected.headers, fn {k, _v} -> k == "location" end) ||
        flunk("no location header on consent 302: #{inspect(redirected.headers)}")

    %URI{query: query} = URI.parse(location)
    params = URI.decode_query(query || "")

    {params["code"], params["state"]}
  end

  # Exchange a consent-minted code with the verifier matching the challenge
  # consented with.
  defp exchange_code(verifier, overrides \\ %{}) do
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    {code, _state} =
      consent_code(%{"code_challenge" => challenge, "code_challenge_method" => "S256"})

    post_token(
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => "l18-client",
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        },
        overrides
      )
    )
  end

  # Signature verification against the JWKS-served public key (real
  # :public_key RSA verify).
  defp verify_with_jwks(id_token) do
    {:ok, resp} =
      Finch.request(
        Finch.build(:get, base() <> "/organizations/discovery/v2.0/keys"),
        L18Finch
      )

    %{"keys" => [jwk]} = Jason.decode!(resp.body)

    [header_b64, payload_b64, sig_b64] = String.split(id_token, ".", parts: 3)
    {:ok, header} = Base.url_decode64(header_b64, padding: false)
    {:ok, claims} = Base.url_decode64(payload_b64, padding: false)
    {:ok, sig} = Base.url_decode64(sig_b64, padding: false)

    n = decode_uint(jwk["n"])
    e = decode_uint(jwk["e"])

    rsa_pub =
      :public_key.der_decode(
        :RSAPublicKey,
        :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, n, e})
      )

    assert :public_key.verify(header_b64 <> "." <> payload_b64, :sha256, sig, rsa_pub)

    {Jason.decode!(header), Jason.decode!(claims)}
  end

  defp decode_uint(b64) do
    {:ok, bin} = Base.url_decode64(b64, padding: false)
    :crypto.bytes_to_integer(bin)
  end

  describe "authorize leg — consent form" do
    @tag :l18_oidc
    test "GET authorize serves the T02 auto-submit consent form" do
      resp = get_authorize()

      assert resp.status == 200
      assert resp.body =~ "onload=\"document.forms[0].submit()\""
      assert resp.body =~ "<noscript>"
      assert resp.body =~ "Continue to l18-client?"

      %{action: action, fields: fields} = parse_form(resp.body)

      assert action == "/organizations/authorize"
      assert fields["client_id"] == "l18-client"
      assert fields["redirect_uri"] == @redirect
      assert fields["response_type"] == "code"
      assert fields["scope"] == "openid profile email"
      assert fields["code_challenge_method"] == "S256"
      assert is_binary(fields["code_challenge"]) and fields["code_challenge"] != ""

      # The form carries the FULL authorization request (same key set the
      # client sent), so the consent POST can re-validate it.
      assert MapSet.new(Map.keys(fields)) == MapSet.new(Map.keys(authorize_params(%{})))
    end

    @tag :l18_oidc
    test "consent POST mints a code bound with challenge+method+client_id+redirect_uri and 302s to the client" do
      {code, state} = consent_code()

      assert is_binary(code) and code != ""
      assert state != ""

      {:ok, record} = OidcCodeStore.peek(code)

      assert record["client_id"] == "l18-client"
      assert record["redirect_uri"] == @redirect
      assert is_binary(record["code_challenge"]) and record["code_challenge"] != ""
      assert record["code_challenge_method"] == "S256"
      assert record["nonce"] != ""
      assert record["tenant"] == "organizations"
      assert record["sub"] == "smalt-user"
    end

    @tag :l18_oidc
    test "authorize-minted code exchanges with PKCE S256 into a JWKS-verifiable id_token" do
      verifier = "l18-verifier-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

      # Consent with THIS verifier's challenge, then exchange with it.
      {code, _} =
        consent_code(%{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      resp =
        post_token(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => "l18-client",
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      assert resp.status == 200
      body = Jason.decode!(resp.body)

      assert body["token_type"] == "Bearer"
      assert body["access_token"] =~ "smalt-at-"
      assert is_binary(body["refresh_token"]) and body["refresh_token"] != ""

      {header, claims} = verify_with_jwks(body["id_token"])

      assert header["alg"] == "RS256"
      assert is_binary(header["kid"]) and header["kid"] != ""
      assert claims["iss"] == base() <> "/organizations/v2.0"
      assert claims["aud"] == "l18-client"
      assert claims["sub"] == "smalt-user"
      assert claims["nonce"] != ""
      assert claims["exp"] > System.system_time(:second)
    end

    @tag :l18_oidc
    test "PKCE plain method round-trips too" do
      verifier = "l18-plain-verifier"

      {code, _} =
        consent_code(%{
          "code_challenge" => verifier,
          "code_challenge_method" => "plain"
        })

      resp =
        post_token(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => "l18-client",
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      assert resp.status == 200
      assert Jason.decode!(resp.body)["id_token"]
    end
  end

  describe "authorize leg — typed refusals" do
    @tag :l18_oidc
    test "response_type other than code is refused" do
      resp = get_authorize(%{"response_type" => "token"})

      assert resp.status == 400
      assert %{"error" => "unsupported_response_type"} = Jason.decode!(resp.body)
    end

    @tag :l18_oidc
    test "missing client_id is refused" do
      resp = get_authorize(%{"client_id" => nil})

      assert resp.status == 400

      assert %{"error" => "invalid_request", "error_description" => "client_id required"} =
               Jason.decode!(resp.body)
    end

    @tag :l18_oidc
    test "missing redirect_uri is refused" do
      resp = get_authorize(%{"redirect_uri" => nil})

      assert resp.status == 400

      assert %{"error" => "invalid_request", "error_description" => "redirect_uri required"} =
               Jason.decode!(resp.body)
    end

    @tag :l18_oidc
    test "non-loopback non-allowlisted redirect_uri is a typed 400, never a redirect" do
      resp = get_authorize(%{"redirect_uri" => "http://evil.example/cb"})

      assert resp.status == 400

      assert %{"error" => "invalid_request", "error_description" => desc} =
               Jason.decode!(resp.body)

      assert desc =~ "redirect_uri not allowed"
    end

    @tag :l18_oidc
    test "allowlisted redirect_uri is accepted" do
      previous = Application.get_env(:smalt, :oidc_idp)

      Application.put_env(:smalt, :oidc_idp,
        allowed_redirect_uris: ["https://court.example/cb"]
      )

      resp = get_authorize(%{"redirect_uri" => "https://court.example/cb"})

      # Restore law: a key restored to a nil VALUE is not the same as an
      # absent key — delete instead (a present-nil env poisons
      # Keyword.get(nil, ...) with a FunctionClauseError).
      case previous do
        nil -> Application.delete_env(:smalt, :oidc_idp)
        kw when is_list(kw) -> Application.put_env(:smalt, :oidc_idp, kw)
      end

      assert resp.status == 200
    end

    @tag :l18_oidc
    test "missing code_challenge is refused (PKCE law)" do
      resp = get_authorize(%{"code_challenge" => nil})

      assert resp.status == 400

      assert %{"error" => "invalid_request", "error_description" => desc} =
               Jason.decode!(resp.body)

      assert desc =~ "code_challenge required"
    end

    @tag :l18_oidc
    test "unknown code_challenge_method is refused" do
      resp = get_authorize(%{"code_challenge_method" => "MD5"})

      assert resp.status == 400
      assert %{"error" => "invalid_request"} = Jason.decode!(resp.body)
    end

    @tag :l18_oidc
    test "scope without openid is refused" do
      resp = get_authorize(%{"scope" => "profile email"})

      assert resp.status == 400
      assert %{"error" => "invalid_scope"} = Jason.decode!(resp.body)
    end
  end

  describe "refresh tokens" do
    @tag :l18_oidc
    test "code grant mints a refresh token; the refresh grant rotates and mints a verifiable id_token" do
      {rt1, id_token} = refresh_source_token()

      assert is_binary(rt1) and rt1 != ""
      row1 = OidcAuthorize.refresh_row(rt1)
      assert row1.consumed == false
      assert row1.record["client_id"] == "l18-client"

      resp =
        post_token(%{
          "grant_type" => "refresh_token",
          "refresh_token" => rt1,
          "client_id" => "l18-client"
        })

      assert resp.status == 200
      body = Jason.decode!(resp.body)

      assert body["token_type"] == "Bearer"
      assert is_binary(body["refresh_token"]) and body["refresh_token"] != rt1
      assert body["refresh_token_expires_in"] == 86_400

      {header, claims} = verify_with_jwks(body["id_token"])
      assert header["alg"] == "RS256"
      assert claims["iss"] == base() <> "/organizations/v2.0"
      assert claims["aud"] == "l18-client"

      assert OidcAuthorize.refresh_row(rt1).consumed == true
    end

    @tag :l18_oidc
    test "replaying a rotated refresh token revokes the whole family" do
      {rt1, _id_token} = refresh_source_token()

      {:ok, resp} = refresh_call(rt1)
      assert resp.status == 200
      %{"refresh_token" => rt2} = Jason.decode!(resp.body)

      # Reuse of the rotated-away token:
      {:ok, replay} = refresh_call(rt1)

      assert replay.status == 400
      assert %{"error" => "invalid_grant", "error_description" => desc} = Jason.decode!(replay.body)
      assert desc =~ "reuse detected"

      # Family law: the rotated-to token is dead too.
      assert OidcAuthorize.refresh_row(rt2) == nil

      {:ok, retry} = refresh_call(rt2)
      assert retry.status == 400
      assert %{"error" => "invalid_grant"} = Jason.decode!(retry.body)
    end

    @tag :l18_oidc
    test "unknown refresh token is refused" do
      {:ok, resp} = refresh_call("rt-never-minted")

      assert resp.status == 400
      assert %{"error" => "invalid_grant", "error_description" => "refresh token not found"} =
               Jason.decode!(resp.body)
    end

    @tag :l18_oidc
    test "client_id mismatch on refresh is refused" do
      {rt1, _id_token} = refresh_source_token()

      {:ok, resp} = refresh_call(rt1, "l18-other-client")

      assert resp.status == 400
      assert %{"error" => "invalid_client", "error_description" => "client_id mismatch"} =
               Jason.decode!(resp.body)

      # Refused consumer never rotated the token: still unconsumed.
      assert OidcAuthorize.refresh_row(rt1).consumed == false
    end
  end

  describe "discovery flip (L17 honest absence now advertised)" do
    @tag :l18_oidc
    test "openid-configuration advertises authorization_endpoint and the refresh grant" do
      resp = get("/organizations/.well-known/openid-configuration")

      assert resp.status == 200
      doc = Jason.decode!(resp.body)

      assert doc["authorization_endpoint"] == base() <> "/organizations/authorize"
      assert doc["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert doc["response_modes_supported"] == ["query"]
    end

    @tag :l18_oidc
    test "oauth-authorization-server advertises the same" do
      resp = get("/organizations/.well-known/oauth-authorization-server")

      assert resp.status == 200
      doc = Jason.decode!(resp.body)

      assert doc["authorization_endpoint"] == base() <> "/organizations/authorize"
      assert doc["grant_types_supported"] == ["authorization_code", "refresh_token"]
    end
  end

  # ------------------------------------------------------------------
  # Shared flow helpers
  # ------------------------------------------------------------------

  # Consent flow + code exchange; returns the minted refresh token and the
  # code-grant id_token.
  defp refresh_source_token do
    verifier = "l18-verifier-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    resp = exchange_code(verifier)

    assert resp.status == 200, "token exchange failed: #{resp.status} #{resp.body}"

    body = Jason.decode!(resp.body)
    {body["refresh_token"], body["id_token"]}
  end

  defp refresh_call(rt, client_id \\ "l18-client") do
    Finch.request(
      Finch.build(
        :post,
        base() <> "/organizations/oauth2/v2.0/token",
        [{"content-type", "application/x-www-form-urlencoded"}],
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => rt,
          "client_id" => client_id
        })
      ),
      L18Finch
    )
  end
end
