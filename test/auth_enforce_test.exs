defmodule Smalt.AuthEnforceTest do
  @moduledoc """
  Enforce-mode spot court for Smalt.Auth.Bearer (S4 defect fix).

  Unlike the anonymous-mode default test config, these tests put
  `:auth_mode` to `:enforce` and exercise the real routers (Plug.Test,
  real token minting with the real STS signing secret — Chicago-style
  real collaborators, no mocks).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  @secret "smalt-auth-enforce-test-secret-0123456789abcdef"
  @aud "https://management.azure.com"
  @iss "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0"

  # The shared tree may be down or on busy default ports (concurrent lanes on
  # this shared checkout): (re)start it on this run's shifted ephemeral ports.
  setup_all do
    if Process.whereis(Smalt.Store) == nil do
      SmaltTest.Lifecycle.restore_app()
    end

    :ok
  end

  setup do
    prev = %{
      auth_mode: Application.get_env(:smalt, :auth_mode),
      sts_signing_secret: Application.get_env(:smalt, :sts_signing_secret),
      token_audiences: Application.get_env(:smalt, :token_audiences)
    }

    Application.put_env(:smalt, :auth_mode, :enforce)
    Application.put_env(:smalt, :sts_signing_secret, @secret)

    on_exit(fn ->
      for {k, v} <- prev do
        if v == :__unset__ do
          Application.delete_env(:smalt, k)
        else
          Application.put_env(:smalt, k, v)
        end
      end
    end)

    :ok
  end

  defp mint(claims_override \\ %{}, signer \\ Joken.Signer.create("HS256", @secret)) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "aud" => @aud,
          "iss" => @iss,
          "iat" => now,
          "nbf" => now,
          "exp" => now + 3600
        },
        claims_override
      )

    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, signer)
    token
  end

  defp arm_req(method, path, headers \\ []) do
    method |> conn(path) |> put_headers(headers) |> Smalt.ArmGateway.Router.call([])
  end

  defp egress_req(method, path, headers) do
    method |> conn(path) |> put_headers(headers) |> Smalt.EgressRouter.call([])
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
  end

  defp assert_challenge(conn, label) do
    assert conn.status == 401, "#{label}: expected 401, got #{conn.status}"

    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "Bearer", "#{label}: WWW-Authenticate must carry the Bearer scheme"
  end

  test "enforce: anonymous GET /subscriptions -> 401 + WWW-Authenticate: Bearer" do
    conn = arm_req(:get, "/subscriptions")
    assert_challenge(conn, "anonymous arm")

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] in ["AuthenticationFailed", "InvalidAuthenticationToken"]
  end

  test "enforce: valid STS-minted bearer -> 200" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions?api-version=2022-09-01", [
        {"authorization", "Bearer #{token}"}
      ])

    assert conn.status == 200, "valid bearer must pass, got #{conn.status}"
  end

  test "enforce: expired token -> 401 TokenExpired" do
    now = System.system_time(:second)
    token = mint(%{"iat" => now - 7200, "nbf" => now - 7200, "exp" => now - 3600})

    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "expired token")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "TokenExpired"
  end

  test "enforce: tampered signature -> 401 SignatureVerificationFailed" do
    token = mint()
    [h, p, sig] = String.split(token, ".")

    flipped =
      sig
      |> :binary.first()
      |> Bitwise.bxor(0x01)
      |> then(&<<&1>>)
      |> Kernel.<>(binary_part(sig, 1, byte_size(sig) - 1))
      |> Base.url_encode64(padding: false)

    tampered = Enum.join([h, p, flipped], ".")
    assert tampered != token

    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer #{tampered}"}])
    assert_challenge(conn, "tampered signature")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "SignatureVerificationFailed"
  end

  test "enforce: wrong-audience token -> 401 AudienceMismatch" do
    token = mint(%{"aud" => "https://vault.smalt.local"})

    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "wrong aud")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "AudienceMismatch"
  end

  test "enforce: wrong-issuer token -> 401 IssuerMismatch" do
    token = mint(%{"iss" => "https://evil.example.com/t/v2.0"})

    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "wrong iss")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "IssuerMismatch"
  end

  test "enforce: cross-secret token -> 401 SignatureVerificationFailed" do
    foreign_signer = Joken.Signer.create("HS256", "completely-other-secret-0123456789abcdef")
    token = mint(%{}, foreign_signer)

    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "cross-secret token")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "SignatureVerificationFailed"
  end

  test "enforce: exempt paths pass without a token" do
    for path <- [
          "/metadata/endpoints",
          "/common/discovery/instance",
          "/.well-known/openid-configuration",
          "/tenants"
        ] do
      conn = arm_req(:get, path)
      assert conn.status == 200, "expected 200 for #{path}, got #{conn.status}"
    end
  end

  test "enforce: egress Cosmos anonymous -> 401" do
    conn =
      egress_req(:post, "/dbs/enforce-db/colls/enforce-db/docs", [
        {"content-type", "application/json"}
      ])

    assert_challenge(conn, "anonymous cosmos")
  end

  test "enforce: malformed Authorization header -> 401" do
    conn = arm_req(:get, "/subscriptions", [{"authorization", "Basic dXNlcjpwYXNz"}])
    assert_challenge(conn, "basic scheme")
  end

  # -- Cycle 1: extract_token fuzz + header robustness + exp boundary ----------

  test "extract: lowercase bearer scheme accepted (RFC 7235 case-insensitive)" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions", [{"authorization", "bearer #{token}"}])

    assert conn.status == 200, "lowercase bearer must pass, got #{conn.status}"
  end

  test "extract: BEARER uppercase scheme accepted" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions", [{"authorization", "BEARER #{token}"}])

    assert conn.status == 200
  end

  test "extract: multi-space padding between scheme and token tolerated" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions", [{"authorization", "Bearer   #{token}"}])

    assert conn.status == 200
  end

  test "extract: empty token (Bearer with no credentials) -> 401" do
    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer "}])
    assert_challenge(conn, "empty bearer")
  end

  test "extract: scheme-only with no space -> 401" do
    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer"}])
    assert_challenge(conn, "no space")
  end

  test "extract: whitespace-only token -> 401" do
    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer    "}])
    assert_challenge(conn, "whitespace token")
  end

  test "extract: non-bearer custom scheme -> 401" do
    conn = arm_req(:get, "/subscriptions", [{"authorization", "Digest abc"}])
    assert_challenge(conn, "digest scheme")
  end

  test "exp boundary: exp == now is refused (exp <= now)" do
    now = System.system_time(:second)
    token = mint(%{"exp" => now})

    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "exp == now")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "TokenExpired"
  end

  test "exp boundary: exp == now + 1 is accepted" do
    now = System.system_time(:second)
    token = mint(%{"exp" => now + 1})

    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer #{token}"}])
    assert conn.status == 200, "exp==now+1 must pass, got #{conn.status}"
  end

  test "header fuzz: malformed x-forwarded-host port does not 500" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "seat.example.com:notaport"}
      ])

    assert conn.status == 200,
           "malformed forwarded port must degrade to direct authority, got #{conn.status}"
  end

  test "header fuzz: non-numeric x-forwarded-host with garbage port still enforces iss" do
    token = mint(%{"iss" => "https://evil.example.com/t/v2.0"})

    conn =
      arm_req(:get, "/subscriptions", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "seat.example.com:notaport"}
      ])

    assert_challenge(conn, "evil iss under malformed forwarded host")
  end

  test "header fuzz: iss is validated against the x-forwarded-host authority" do
    tid = "00000000-0000-0000-0000-000000000000"
    now = System.system_time(:second)

    claims = %{
      "aud" => @aud,
      "iss" => "https://fwd.example.com/#{tid}/v2.0",
      "iat" => now,
      "nbf" => now,
      "exp" => 3600 + now
    }

    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, Joken.Signer.create("HS256", @secret))

    conn =
      arm_req(:get, "/subscriptions", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "fwd.example.com"},
        {"x-forwarded-proto", "https"}
      ])

    assert conn.status == 200,
           "token minted for the forwarded authority must pass, got #{conn.status}"

    # Same token against a different forwarded authority -> IssuerMismatch
    conn2 =
      arm_req(:get, "/subscriptions", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "other.example.com"},
        {"x-forwarded-proto", "https"}
      ])

    assert_challenge(conn2, "wrong forwarded authority")
    assert Jason.decode!(conn2.resp_body)["error"]["message"] =~ "IssuerMismatch"
  end

  test "claims fuzz: non-binary iss -> 401 IssuerMismatch (catch-all clause)" do
    token = mint(%{"iss" => 12_345})

    conn = arm_req(:get, "/subscriptions", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "non-binary iss")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "IssuerMismatch"
  end

  test "anonymous mode: no token required (explicit opt-out honoured)" do
    Application.put_env(:smalt, :auth_mode, :anonymous)

    conn = arm_req(:get, "/subscriptions")
    assert conn.status == 200
  after
    Application.put_env(:smalt, :auth_mode, :enforce)
  end
end
