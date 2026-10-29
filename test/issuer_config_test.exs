defmodule Smalt.IssuerConfigTest do
  @moduledoc """
  Lane R9 (JWT issuer configurability) court: `config :smalt, :issuer_host`
  re-points the STS mint + OIDC discovery authority. Default (nil) is
  byte-identical to the legacy request-derived mint; a configured host mints
  `iss: https://<host>/<tenant>/v2.0`, keeps the discovery issuer in exact
  lockstep, and the token still verifies via the existing verification path
  (signature + kid binding untouched). Malformed values refuse fail-closed.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.Auth.StsKey
  alias Smalt.ArmGateway.Router

  @tenant "smalt-tenant"
  @trusted_key_prefix :trusted

  defp dispatch(conn), do: Router.call(conn, [])

  # Deterministic env: each test starts from the config-off default, and the
  # env is removed after the suite so later suites see the default.
  setup do
    Application.delete_env(:smalt, :issuer_host)

    on_exit(fn -> Application.delete_env(:smalt, :issuer_host) end)

    :ok
  end

  defp mint_token(path \\ "/#{@tenant}/oauth2/v2.0/token") do
    conn =
      :post
      |> conn(path, %{"grant_type" => "client_credentials", "client_id" => "test", "client_secret" => "test"})
      |> dispatch()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    # D8 (identity/sts-token@key-missing:scope): real Entra client_credentials
    # responses carry a `scope` member — the granted scopes. The emulator's
    # model mints for the ARM audience, so the faithful value is aud + "/.default".
    assert body["scope"] == "https://management.azure.com/.default"
    assert body["token_type"] == "Bearer"
    token = body["access_token"]
    assert is_binary(token)
    token
  end

  defp claims_of(token) do
    {:ok, claims} = Joken.verify_and_validate(%{}, token, StsKey.signer())
    claims
  end

  # -- default: byte-identical legacy issuer -----------------------------------

  test "default (issuer_host unset) mints the legacy request-derived issuer" do
    assert Smalt.Config.issuer_host() == nil

    token = mint_token()

    # Plug.Test conn: scheme http, host "www.example.com", port 80 — the
    # legacy direct-authority derivation, no schemeless/forwarded variant.
    assert claims_of(token)["iss"] == "http://www.example.com/smalt-tenant/v2.0"
  end

  # -- configured host ----------------------------------------------------------

  test "configured bare host mints iss with the new authority; discovery issuer matches" do
    Application.put_env(:smalt, :issuer_host, "sts.corp.example")

    token = mint_token()

    assert claims_of(token)["iss"] == "https://sts.corp.example/smalt-tenant/v2.0"

    # OIDC lockstep: the discovery doc's issuer EXACTLY equals the minted iss.
    conn =
      :get
      |> conn("/#{@tenant}/v2.0/.well-known/openid-configuration")
      |> dispatch()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["issuer"] == "https://sts.corp.example/smalt-tenant/v2.0"
  end

  test "configured full HTTPS URL (no path) is accepted and normalized" do
    Application.put_env(:smalt, :issuer_host, "https://sts.corp.example")

    token = mint_token()

    assert claims_of(token)["iss"] == "https://sts.corp.example/smalt-tenant/v2.0"
  end

  test "kid binding unaffected: RS256 header kid still the RFC 7638 thumbprint" do
    Application.put_env(:smalt, :issuer_host, "sts.corp.example")

    token = mint_token()
    {:ok, header} = Joken.peek_header(token)

    assert header["kid"] == StsKey.kid()
    assert header["alg"] == "RS256"
  end

  test "configured-host token still verifies via the existing verification path" do
    Application.put_env(:smalt, :issuer_host, "sts.corp.example")

    token = mint_token()

    # The existing path: signature verify with the mode's signer, then the
    # Bearer issuer law (config-off = request-authority leg can't match a
    # foreign authority; the cross-seat registry leg must). The mint
    # registered "https://sts.corp.example" as a trusted mint authority, so
    # the issuer check admits it.
    assert %{"iss" => "https://sts.corp.example/smalt-tenant/v2.0"} = claims_of(token)

    authority = "https://sts.corp.example"
    assert :persistent_term.get({Smalt.Auth.Bearer, @trusted_key_prefix, authority}, false)
  end

  # -- fail-closed malformed values ---------------------------------------------

  test "http-scheme issuer_host refuses the mint with ArgumentError" do
    Application.put_env(:smalt, :issuer_host, "http://sts.corp.example")

    assert_raise Plug.Conn.WrapperError, ~r/:issuer_host/, fn ->
      :post
      |> conn("/#{@tenant}/oauth2/v2.0/token", %{
        "grant_type" => "client_credentials",
        "client_id" => "t",
        "client_secret" => "t"
      })
      |> dispatch()
    end
  end

  test "issuer_host with embedded path refuses the mint" do
    Application.put_env(:smalt, :issuer_host, "https://sts.corp.example/courtroom-ai")

    assert_raise Plug.Conn.WrapperError, ~r/:issuer_host/, fn ->
      :post
      |> conn("/#{@tenant}/oauth2/v2.0/token", %{
        "grant_type" => "client_credentials",
        "client_id" => "t",
        "client_secret" => "t"
      })
      |> dispatch()
    end
  end

  test "blank issuer_host refuses the mint" do
    Application.put_env(:smalt, :issuer_host, "")

    assert_raise Plug.Conn.WrapperError, ~r/:issuer_host/, fn ->
      :post
      |> conn("/#{@tenant}/oauth2/v2.0/token", %{
        "grant_type" => "client_credentials",
        "client_id" => "t",
        "client_secret" => "t"
      })
      |> dispatch()
    end
  end

  # -- env hygiene ---------------------------------------------------------------

  test "issuer_host restore leaves the default mint intact" do
    Application.put_env(:smalt, :issuer_host, "sts.corp.example")
    _ = mint_token()
    Application.delete_env(:smalt, :issuer_host)

    token = mint_token()
    assert claims_of(token)["iss"] == "http://www.example.com/smalt-tenant/v2.0"
  end

  # Registered authorities live in :persistent_term for the VM lifetime; erase
  # the ones this suite minted under so other suites see a clean registry.
  setup_all do
    on_exit(fn ->
      :persistent_term.erase({@trusted_key_prefix, "https://sts.corp.example"})
    end)

    :ok
  end
end
