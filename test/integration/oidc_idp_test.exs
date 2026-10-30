defmodule Smalt.Identity.OidcIdpTest do
  @moduledoc """
  T05 lane L17: real-server integration court for the OIDC IdP discovery +
  token legs. Real Bandit HTTP server, real HTTP over Finch, real RSA
  verification against the JWKS-served key. No mocks, no sleeps — readiness
  is synchronous: Thousand Island binds its listener before Bandit's
  start_link returns, so first-request failure is a typed failure, not a
  race.
  """

  use ExUnit.Case, async: false

  alias Smalt.Identity.OidcCodeStore
  alias Smalt.Identity.OidcIdp

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
    port = 49_700 + :rand.uniform(2_000)

    case bandit_up?(port) do
      true -> start_server(attempt + 1)
      false ->
        Application.put_env(:smalt, :oidc_port, port)

        case Supervisor.start_link([{Finch, name: L17Finch}, {OidcIdp, port: port}],
               strategy: :one_for_one,
               name: L17OidcTestSup
             ) do
          {:ok, sup} ->
            on_exit(fn -> Supervisor.stop(sup) end)
            port

          {:error, {{:shutdown, {_, _, {:eaddrinuse, _}}}, _}} ->
            start_server(attempt + 1)
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
    {:ok, resp} = Finch.request(Finch.build(:get, base() <> path), L17Finch)
    resp
  end

  defp post_token(form) do
    body = URI.encode_query(form)

    req =
      Finch.build(:post, base() <> "/organizations/oauth2/v2.0/token", [
        {"content-type", "application/x-www-form-urlencoded"}
      ], body)

    {:ok, resp} = Finch.request(req, L17Finch)
    resp
  end

  defp seed_code(extra \\ %{}) do
    code = "l17-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    base_attrs = %{
      "client_id" => "l17-client",
      "redirect_uri" => @redirect,
      "sub" => "l17-subject",
      "tenant" => "organizations"
    }

    :ok = OidcCodeStore.insert(code, Map.merge(base_attrs, extra))
    code
  end

  # Signature verification against the JWKS-served public key (real
  # :public_key RSA verify, same math the node openid-client court does).
  defp verify_with_jwks(id_token) do
    {:ok, resp} = Finch.request(Finch.build(:get, base() <> "/organizations/discovery/v2.0/keys"), L17Finch)
    %{"keys" => [jwk]} = Jason.decode!(resp.body)

    [header_b64, payload_b64, sig_b64] = String.split(id_token, ".", parts: 3)
    {:ok, header} = Base.url_decode64(header_b64, padding: false)
    {:ok, claims} = Base.url_decode64(payload_b64, padding: false)
    {:ok, sig} = Base.url_decode64(sig_b64, padding: false)

    n = decode_uint(jwk["n"])
    e = decode_uint(jwk["e"])
    rsa_pub = :public_key.der_decode(:RSAPublicKey, :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, n, e}))

    assert :public_key.verify(header_b64 <> "." <> payload_b64, :sha256, sig, rsa_pub)

    {Jason.decode!(header), Jason.decode!(claims)}
  end

  defp decode_uint(b64) do
    {:ok, bin} = Base.url_decode64(b64, padding: false)
    :crypto.bytes_to_integer(bin)
  end

  describe "discovery documents" do
    @tag :l17_oidc
    test "openid-configuration advertises only existing endpoints" do
      resp = get("/organizations/.well-known/openid-configuration")
      assert resp.status == 200

      doc = Jason.decode!(resp.body)
      assert doc["issuer"] =~ "/organizations/v2.0"
      assert doc["token_endpoint"] == base() <> "/organizations/oauth2/v2.0/token"
      assert doc["jwks_uri"] == base() <> "/organizations/discovery/v2.0/keys"
      assert doc["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert doc["code_challenge_methods_supported"] == ["S256", "plain"]

      # L18 flipped the honest absence: /authorize exists, so it is
      # advertised (disclosed in r-t05a + r-t05b).
      assert doc["authorization_endpoint"] == base() <> "/organizations/authorize"
    end

    @tag :l17_oidc
    test "Entra v2 discovery path (issuer-path insertion) serves the same doc" do
      resp = get("/organizations/v2.0/.well-known/openid-configuration")
      assert resp.status == 200

      doc = Jason.decode!(resp.body)
      assert doc["issuer"] == base() <> "/organizations/v2.0"
      assert doc["token_endpoint"] == base() <> "/organizations/oauth2/v2.0/token"

      # L18 flip: advertised now that the leg exists.
      assert doc["authorization_endpoint"] == base() <> "/organizations/authorize"
    end

    @tag :l17_oidc
    test "oauth-authorization-server (RFC 8414) mirrors the same truth" do
      resp = get("/organizations/.well-known/oauth-authorization-server")
      assert resp.status == 200

      doc = Jason.decode!(resp.body)
      assert doc["issuer"] =~ "/organizations/v2.0"
      assert doc["token_endpoint"] == base() <> "/organizations/oauth2/v2.0/token"
      assert doc["jwks_uri"] == base() <> "/organizations/discovery/v2.0/keys"

      # L18 flip: advertised now that the leg exists.
      assert doc["authorization_endpoint"] == base() <> "/organizations/authorize"
    end

    @tag :l17_oidc
    test "JWKS serves the dev-cert RSA public key" do
      resp = get("/organizations/discovery/v2.0/keys")
      assert resp.status == 200

      %{"keys" => [jwk]} = Jason.decode!(resp.body)
      {:ok, expected} = Smalt.Identity.OidcJwks.jwk()

      assert jwk["kty"] == "RSA"
      assert jwk["alg"] == "RS256"
      assert jwk["use"] == "sig"
      assert jwk["kid"] == expected["kid"]
      assert jwk["e"] == "AQAB"
      assert byte_size(jwk["n"]) > 200
    end
  end

  describe "token leg" do
    @tag :l17_oidc
    test "authorization-code + PKCE S256 mints a verifiable RS256 id_token" do
      verifier = "l17-verifier-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

      challenge =
        :crypto.hash(:sha256, verifier)
        |> Base.url_encode64(padding: false)

      code =
        seed_code(%{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "nonce" => "l17-nonce-123"
        })

      resp =
        post_token(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => "l17-client",
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      assert resp.status == 200
      body = Jason.decode!(resp.body)

      assert body["token_type"] == "Bearer"
      assert body["scope"] == "openid profile email"
      assert body["expires_in"] == 3600
      assert is_binary(body["access_token"])

      {header, claims} = verify_with_jwks(body["id_token"])
      assert header["alg"] == "RS256"
      assert is_binary(header["kid"]) and header["kid"] != ""
      assert claims["iss"] == base() <> "/organizations/v2.0"
      assert claims["aud"] == "l17-client"
      assert claims["sub"] == "l17-subject"
      assert claims["nonce"] == "l17-nonce-123"
      assert claims["exp"] > System.system_time(:second)
    end

    @tag :l17_oidc
    test "PKCE plain path also exchanges" do
      verifier = "l17-plain-verifier-abc123"

      code =
        seed_code(%{
          "code_challenge" => verifier,
          "code_challenge_method" => "plain"
        })

      resp =
        post_token(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => "l17-client",
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      assert resp.status == 200
      assert Jason.decode!(resp.body)["id_token"]
    end

    @tag :l17_oidc
    test "code replay is refused (single-use)" do
      verifier = "l17-replay-verifier"

      code =
        seed_code(%{
          "code_challenge" => :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false),
          "code_challenge_method" => "S256"
        })

      form = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => "l17-client",
        "redirect_uri" => @redirect,
        "code_verifier" => verifier
      }

      assert post_token(form).status == 200
      replay = post_token(form)

      assert replay.status == 400
      assert %{"error" => "invalid_grant"} = Jason.decode!(replay.body)
    end

    @tag :l17_oidc
    test "wrong code_verifier is refused" do
      challenge =
        :crypto.hash(:sha256, "the-real-verifier")
        |> Base.url_encode64(padding: false)

      code =
        seed_code(%{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      resp =
        post_token(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => "l17-client",
          "redirect_uri" => @redirect,
          "code_verifier" => "the-wrong-verifier"
        })

      assert resp.status == 400

      assert %{"error" => "invalid_grant", "error_description" => desc} =
               Jason.decode!(resp.body)

      assert desc =~ "PKCE"
    end

    @tag :l17_oidc
    test "redirect_uri mismatch is refused" do
      code = seed_code(%{})

      resp =
        post_token(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => "l17-client",
          "redirect_uri" => "http://evil.example/callback",
          "code_verifier" => "unused"
        })

      assert resp.status == 400
      assert %{"error" => "invalid_grant"} = Jason.decode!(resp.body)
    end

    @tag :l17_oidc
    test "unsupported grant_type is refused" do
      code = seed_code(%{})

      resp =
        post_token(%{
          "grant_type" => "client_credentials",
          "code" => code,
          "client_id" => "l17-client"
        })

      assert resp.status == 400
      assert %{"error" => "unsupported_grant_type"} = Jason.decode!(resp.body)
    end

    @tag :l17_oidc
    test "unknown code is refused" do
      resp =
        post_token(%{
          "grant_type" => "authorization_code",
          "code" => "never-issued",
          "client_id" => "l17-client",
          "redirect_uri" => @redirect,
          "code_verifier" => "whatever"
        })

      assert resp.status == 400
      assert %{"error" => "invalid_grant"} = Jason.decode!(resp.body)
    end
  end
end