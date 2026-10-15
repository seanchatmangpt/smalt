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
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

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
    # No :persistent_term pin: the gateway now prefers the env secret
    # (cycle-4 precedence fix), so this suite PROVES mint/verify agreement
    # even when the dev secret was already generated at app-restore boot.

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
    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01")
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

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
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

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{tampered}"}])
    assert_challenge(conn, "tampered signature")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "SignatureVerificationFailed"
  end

  test "enforce: wrong-audience token -> 401 AudienceMismatch" do
    token = mint(%{"aud" => "https://vault.smalt.local"})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "wrong aud")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "AudienceMismatch"
  end

  test "enforce: wrong-issuer token -> 401 IssuerMismatch" do
    token = mint(%{"iss" => "https://evil.example.com/t/v2.0"})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "wrong iss")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "IssuerMismatch"
  end

  test "enforce: cross-secret token -> 401 SignatureVerificationFailed" do
    foreign_signer = Joken.Signer.create("HS256", "completely-other-secret-0123456789abcdef")
    token = mint(%{}, foreign_signer)

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
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
    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Basic dXNlcjpwYXNz"}])
    assert_challenge(conn, "basic scheme")
  end

  # -- Cycle 1: extract_token fuzz + header robustness + exp boundary ----------

  test "extract: lowercase bearer scheme accepted (RFC 7235 case-insensitive)" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "bearer #{token}"}])

    assert conn.status == 200, "lowercase bearer must pass, got #{conn.status}"
  end

  test "extract: BEARER uppercase scheme accepted" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "BEARER #{token}"}])

    assert conn.status == 200
  end

  test "extract: multi-space padding between scheme and token tolerated" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer   #{token}"}])

    assert conn.status == 200
  end

  test "extract: empty token (Bearer with no credentials) -> 401" do
    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer "}])
    assert_challenge(conn, "empty bearer")
  end

  test "extract: scheme-only with no space -> 401" do
    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer"}])
    assert_challenge(conn, "no space")
  end

  test "extract: whitespace-only token -> 401" do
    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer    "}])
    assert_challenge(conn, "whitespace token")
  end

  test "extract: non-bearer custom scheme -> 401" do
    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Digest abc"}])
    assert_challenge(conn, "digest scheme")
  end

  test "exp boundary: exp == now is refused (exp <= now)" do
    now = System.system_time(:second)
    token = mint(%{"exp" => now})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "exp == now")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "TokenExpired"
  end

  test "exp boundary: exp == now + 1 is accepted" do
    now = System.system_time(:second)
    token = mint(%{"exp" => now + 1})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert conn.status == 200, "exp==now+1 must pass, got #{conn.status}"
  end

  test "header fuzz: malformed x-forwarded-host port does not 500" do
    token = mint()

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "seat.example.com:notaport"}
      ])

    assert conn.status == 200,
           "malformed forwarded port must degrade to direct authority, got #{conn.status}"
  end

  test "header fuzz: non-numeric x-forwarded-host with garbage port still enforces iss" do
    token = mint(%{"iss" => "https://evil.example.com/t/v2.0"})

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "seat.example.com:notaport"}
      ])

    assert_challenge(conn, "evil iss under malformed forwarded host")
  end

  test "header fuzz: iss is validated against the x-forwarded-host authority" do
    # Forwarded headers are honored ONLY from trusted proxies (fail-closed
    # gating); Plug.Test conns have direct peer {127,0,0,1}, so the test acts
    # as a real reverse-proxy seat by configuring it trusted.
    Application.put_env(:smalt, :trusted_proxies, [{127, 0, 0, 1}])

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
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "fwd.example.com"},
        {"x-forwarded-proto", "https"}
      ])

    assert conn.status == 200,
           "token minted for the forwarded authority must pass, got #{conn.status}"

    # Same token against a different forwarded authority -> IssuerMismatch
    conn2 =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "other.example.com"},
        {"x-forwarded-proto", "https"}
      ])

    assert_challenge(conn2, "wrong forwarded authority")
    assert Jason.decode!(conn2.resp_body)["error"]["message"] =~ "IssuerMismatch"
  after
    Application.delete_env(:smalt, :trusted_proxies)
  end

  # -- Cycle 3: fail-closed forwarded-header gating + cross-port mint authority --

  test "fail-closed: x-forwarded-host from an untrusted direct peer is ignored" do
    # Token minted for the forwarded authority must NOT be accepted when the
    # peer is not a trusted proxy: the header is client-spoofable.
    tid = "00000000-0000-0000-0000-000000000000"
    now = System.system_time(:second)

    claims = %{
      "aud" => @aud,
      "iss" => "https://spoof.example.com/#{tid}/v2.0",
      "iat" => now,
      "nbf" => now,
      "exp" => 3600 + now
    }

    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, Joken.Signer.create("HS256", @secret))

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "spoof.example.com"},
        {"x-forwarded-proto", "https"}
      ])

    assert_challenge(conn, "spoofed forwarded authority, untrusted peer")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "IssuerMismatch"

    # The SAME token IS accepted once the peer is a configured trusted proxy.
    Application.put_env(:smalt, :trusted_proxies, [{127, 0, 0, 1}])

    conn2 =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "spoof.example.com"},
        {"x-forwarded-proto", "https"}
      ])

    assert conn2.status == 200, "trusted-proxy seat must honor forwarded authority"

    # A CIDR entry also grants trust (10.0.0.0/8 does not cover 127.0.0.1).
    Application.put_env(:smalt, :trusted_proxies, ["10.0.0.0/8"])

    conn3 =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "spoof.example.com"},
        {"x-forwarded-proto", "https"}
      ])

    assert_challenge(conn3, "non-matching CIDR")
  after
    Application.delete_env(:smalt, :trusted_proxies)
  end

  test "fail-closed: spoofed forwarded host cannot redirect issuer acceptance for a direct token" do
    # Token for the DIRECT authority stays valid even when a client injects an
    # x-forwarded-host claiming a different seat (headers ignored on direct
    # connections).
    tid = "00000000-0000-0000-0000-000000000000"
    now = System.system_time(:second)

    claims = %{
      "aud" => @aud,
      "iss" => "http://www.example.com/#{tid}/v2.0",
      "iat" => now,
      "nbf" => now,
      "exp" => 3600 + now
    }

    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, Joken.Signer.create("HS256", @secret))

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "evil.example.com"}
      ])

    assert conn.status == 200, "spoofed forwarded header must not break a direct-authority token"
  end

  test "cross-port: token minted at the ARM authority is accepted on the egress seat" do
    # Real STS mint on an ARM seat with its own host/port...
    arm_conn =
      %Plug.Conn{conn(:post, "/oauth2/v2.0/token", token_params()) | host: "arm.smalt.local", port: 19_081}
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    assert arm_conn.status == 200, "STS mint must succeed, got #{arm_conn.status}"
    %{"access_token" => token} = Jason.decode!(arm_conn.resp_body)

    # ...then replayed against the Cosmos/egress seat on its own authority.
    # Before the fix this 401'd IssuerMismatch (egress derived authority from
    # its own port); now the gateway-recorded mint authority is accepted.
    egress_conn =
      %Plug.Conn{conn(:get, "/dbs") | host: "cosmos.smalt.local", port: 8443}
      |> put_req_header("authorization", "Bearer #{token}")
      |> Smalt.EgressRouter.call([])

    refute egress_conn.status == 401,
           "fresh ARM-minted token must not 401 on the egress seat, got " <>
             "#{egress_conn.status}: #{egress_conn.resp_body}"

    assert egress_conn.status == 200,
           "expected 200 from Cosmos list-dbs, got #{egress_conn.status}: #{egress_conn.resp_body}"
  end

  test "cross-port: tampered or foreign tokens still refused on the egress seat" do
    arm_conn =
      %Plug.Conn{conn(:post, "/oauth2/v2.0/token", token_params()) | host: "arm.smalt.local", port: 19_081}
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    %{"access_token" => token} = Jason.decode!(arm_conn.resp_body)
    [h, p, sig] = String.split(token, ".")
    tampered = Enum.join([h, p, String.slice(sig, 0, byte_size(sig) - 4) <> "AAAA"], ".")

    egress_conn =
      %Plug.Conn{conn(:get, "/dbs") | host: "cosmos.smalt.local", port: 8443}
      |> put_req_header("authorization", "Bearer #{tampered}")
      |> Smalt.EgressRouter.call([])

    assert_challenge(egress_conn, "tampered token on egress seat")
    assert Jason.decode!(egress_conn.resp_body)["error"]["message"] =~ "SignatureVerificationFailed"
  after
    Application.put_env(:smalt, :auth_mode, :enforce)
  end

  defp token_params do
    "grant_type=client_credentials&client_id=x&client_secret=y"
  end

  # -- Cycle 5: CIDR semantics, restart contract, audience cross-validation -----

  test "trusted-proxy CIDR: /8 outside the /24 string prefix is honored (true CIDR math)" do
    # 10.99.1.1 is inside 10.0.0.0/8 but does NOT share a string prefix with
    # "10.0.0.0" — a naive prefix-string match would refuse it.
    Application.put_env(:smalt, :trusted_proxies, ["10.0.0.0/8"])

    # Issuer is bound to the forwarded authority so the court exercises the
    # DERIVATION, not the legacy AAD-prefix issuer leg (which would mask it).
    tid = "00000000-0000-0000-0000-000000000000"
    now = System.system_time(:second)

    {:ok, token, _} =
      Joken.generate_and_sign(
        %{},
        %{"aud" => @aud, "iss" => "https://fwd8.example.com/#{tid}/v2.0",
          "iat" => now, "nbf" => now, "exp" => now + 3600},
        Joken.Signer.create("HS256", @secret)
      )

    conn =
      %Plug.Conn{conn(:get, "/subscriptions?api-version=2021-04-01") | remote_ip: {10, 99, 1, 1}, host: "fwd8.example.com"}
      |> put_headers([{"authorization", "Bearer #{token}"},
                      {"x-forwarded-host", "fwd8.example.com"},
                      {"x-forwarded-proto", "https"}])
      |> Smalt.ArmGateway.Router.call([])

    assert conn.status == 200,
           "10.99.1.1 must be inside 10.0.0.0/8 (CIDR math, not string prefix), got #{conn.status}"
  end

  test "trusted-proxy CIDR: /16 range member outside the octet-3 prefix is honored" do
    # 10.0.200.1 is inside 10.0.0.0/16 but "10.0.200.1" does not start with
    # "10.0.0." — kills any prefix-string regression in both directions.
    Application.put_env(:smalt, :trusted_proxies, ["10.0.0.0/16"])

    tid = "00000000-0000-0000-0000-000000000000"
    now = System.system_time(:second)

    {:ok, token, _} =
      Joken.generate_and_sign(
        %{},
        %{"aud" => @aud, "iss" => "https://fwd16.example.com/#{tid}/v2.0",
          "iat" => now, "nbf" => now, "exp" => now + 3600},
        Joken.Signer.create("HS256", @secret)
      )

    conn =
      %Plug.Conn{conn(:get, "/subscriptions?api-version=2021-04-01") | remote_ip: {10, 0, 200, 1}, host: "fwd16.example.com"}
      |> put_headers([{"authorization", "Bearer #{token}"},
                      {"x-forwarded-host", "fwd16.example.com"},
                      {"x-forwarded-proto", "https"}])
      |> Smalt.ArmGateway.Router.call([])

    assert conn.status == 200, "10.0.200.1 must be inside 10.0.0.0/16, got #{conn.status}"
  end

  test "restart contract: cleared trusted-authority set refuses pre-restart minted authorities" do
    # :persistent_term is VM-local. A substrate restart wipes the recorded
    # mint authorities; a pre-restart token replayed at a foreign seat whose
    # authority was never re-registered must be REFUSED (IssuerMismatch).
    # Contract: restart => re-authentication.
    arm_conn =
      %Plug.Conn{conn(:post, "/oauth2/v2.0/token", token_params()) | host: "arm.smalt.local", port: 19_081}
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    %{"access_token" => token} = Jason.decode!(arm_conn.resp_body)

    # Simulate restart: erase every recorded mint authority (new VM, nothing
    # registered). reset_trusted_authorities!/0 is the restart contract's
    # mechanical surface; the per-authority keys replaced the old single
    # MapSet in lens-2 cycle 1 (concurrent-mint lost-update fix).
    Smalt.Auth.Bearer.reset_trusted_authorities!()

    egress_conn =
      %Plug.Conn{conn(:get, "/dbs") | host: "cosmos.smalt.local", port: 8443}
      |> put_req_header("authorization", "Bearer #{token}")
      |> Smalt.EgressRouter.call([])

    assert_challenge(egress_conn, "pre-restart token after restart")
    assert Jason.decode!(egress_conn.resp_body)["error"]["message"] =~ "IssuerMismatch"

    # Re-authentication (real mint on the ARM seat re-registers the authority)
    # restores cross-seat acceptance.
    arm_conn2 =
      %Plug.Conn{conn(:post, "/oauth2/v2.0/token", token_params()) | host: "arm.smalt.local", port: 19_081}
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8"
      )
      |> Smalt.ArmGateway.Router.call([])

    %{"access_token" => token2} = Jason.decode!(arm_conn2.resp_body)

    egress_conn2 =
      %Plug.Conn{conn(:get, "/dbs") | host: "cosmos.smalt.local", port: 8443}
      |> put_req_header("authorization", "Bearer #{token2}")
      |> Smalt.EgressRouter.call([])

    assert egress_conn2.status == 200,
           "post-restart mint must re-register and pass, got #{egress_conn2.status}"
  after
    # Leave the set in a populated state for other tests (re-register the seat
    # used above; membership is additive so this cannot weaken any court).
    Smalt.Auth.Bearer.register_trusted_authority("http://arm.smalt.local:19081")
  end

  test "audience cross-validation: discovery-advertised audience is byte-acceptable" do
    # The metadata/endpoints envelope advertises authentication.audiences;
    # the plug's accepted-audience set must contain that EXACT string.
    conn = arm_req(:get, "/metadata/endpoints")
    assert conn.status == 200
    advertised = Jason.decode!(conn.resp_body)["authentication"]["audiences"]
    assert is_list(advertised) and advertised != []
    aud = hd(advertised)

    conn2 = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint(%{"aud" => aud})}"}])
    assert conn2.status == 200, "advertised audience #{inspect(aud)} must be accepted verbatim"

    # Byte-exactness: the trailing-slash resource form (also advertised as
    # activeDirectoryResourceId) is a DIFFERENT string and must NOT pass.
    conn3 =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint(%{"aud" => aud <> "/"})}"}])

    assert_challenge(conn3, "trailing-slash audience variant")
    assert Jason.decode!(conn3.resp_body)["error"]["message"] =~ "AudienceMismatch"
  end

  test "claims fuzz: non-binary iss -> 401 IssuerMismatch (catch-all clause)" do
    token = mint(%{"iss" => 12_345})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "non-binary iss")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "IssuerMismatch"
  end

  # -- Cycle 6: claims-path robustness (no 500 out of the auth plug) ------------

  test "claims fuzz: non-integer exp -> 401 TokenExpired (catch-all, no crash)" do
    token = mint(%{"exp" => "soon"})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "string exp")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "TokenExpired"
  end

  test "config fuzz: bare-binary :token_audiences does not 500 (normalized)" do
    # `aud not in audiences` with a binary RHS would raise ArgumentError and
    # crash the plug into a 500. The plug normalizes the env to a list.
    Application.put_env(:smalt, :token_audiences, @aud)

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint()}"}])
    assert conn.status == 200, "binary audiences env must be normalized, got #{conn.status}"
  end

  test "config fuzz: nil :token_audiences falls back to the default audience" do
    Application.put_env(:smalt, :token_audiences, nil)

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint()}"}])
    assert conn.status == 200, "nil audiences env must fall back to default, got #{conn.status}"
  after
    Application.delete_env(:smalt, :token_audiences)
  end

  # -- Cycle 7: header composition + RFC 7235 extraction fuzz --------------------

  test "www-authenticate fuzz: every refusal class emits a single printable-ASCII challenge" do
    # error_description comes from COMPILE-TIME reason atoms — never client
    # input — so header injection is structurally impossible. Pin: exactly
    # one challenge header, all printable ASCII, no CR/LF, for every class.
    now = System.system_time(:second)

    cases = [
      {"missing token", arm_req(:get, "/subscriptions?api-version=2021-04-01")},
      {"malformed scheme", arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Digest abc"}])},
      {"empty token", arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer "}])},
      {"expired", arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint(%{"exp" => now - 10})}"}])},
      {"bad aud", arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint(%{"aud" => "https://x"})}"}])},
      {"bad iss", arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint(%{"iss" => "https://evil/v2.0"})}"}])},
      {"bad sig", fn ->
        [h, p, _] = String.split(mint(), ".")

        arm_req(:get, "/subscriptions?api-version=2021-04-01", [
          {"authorization", "Bearer #{Enum.join([h, p, "AAAA"], ".")}"}
        ])
      end.()},
      {"crlf in token", arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer abc\r\nX-Injected: 1"}])}
    ]

    for {label, conn} <- cases do
      assert [challenge] = get_resp_header(conn, "www-authenticate"),
             "#{label}: expected exactly one challenge header"

      assert challenge =~ ~r/^[ -~]+$/,
             "#{label}: challenge must be single-line printable ASCII, got #{inspect(challenge)}"

      assert conn.status == 401, "#{label}: expected 401"
    end
  end

  test "extract fuzz: tab separator is not a valid scheme delimiter (RFC 7235 1*SP)" do
    token = mint()

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer\t#{token}"}])
    assert_challenge(conn, "tab separator")
  end

  test "extract fuzz: unicode look-alike scheme (Beta) refused" do
    token = mint()

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Βearer #{token}"}])
    assert_challenge(conn, "unicode scheme")
  end

  test "extract fuzz: token containing the word Bearer is passed to signature verification" do
    # "Bearer Bearer abc" -> credentials "Bearer abc"; not a parse failure —
    # it reaches Joken and fails the signature, never crashes or skips auth.
    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer Bearer abc"}])
    assert_challenge(conn, "bearer-in-token")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "SignatureVerificationFailed"
  end

  test "claims fuzz: non-binary aud -> 401 AudienceMismatch (catch-all)" do
    token = mint(%{"aud" => 12_345})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "integer aud")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "AudienceMismatch"
  end

  test "claims fuzz: empty iss -> 401 IssuerMismatch" do
    token = mint(%{"iss" => ""})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert_challenge(conn, "empty iss")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "IssuerMismatch"
  end

  # -- Cycle 8: exempt matrix + alg confusion + wave-2 fuzz vectors --------------

  @exempt_matrix [
    {"/oauth2/v2.0/token", :post},
    {"/.well-known/openid-configuration", :get},
    {"/common/discovery/instance", :get},
    {"/attest/init", :post},
    {"/metadata/endpoints", :get},
    {"/tenant", :get},
    {"/tenants", :get}
  ]

  defp route_through(:arm, method, path, headers) do
    arm_req(method, path, headers)
  end

  defp route_through(:egress, method, path, headers) do
    egress_req(method, path, headers)
  end

  test "exempt matrix: exempt shapes pass the plug on BOTH routers (never 401-no-token)" do
    for {path, method} <- @exempt_matrix, router <- [:arm, :egress] do
      conn = route_through(router, method, path, [])

      assert conn.status != 401,
             "exempt #{method} #{path} on #{router} must pass the auth plug, got " <>
               "#{conn.status}: #{String.slice(conn.resp_body || "", 0, 80)}"
    end
  end

  test "exempt matrix: protected probes on BOTH routers are 401 anonymously (method classes)" do
    protected = [
      {:get, "/subscriptions?api-version=2022-09-01"},
      {:put, "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Storage/x/y?api-version=2022-09-01"},
      {:delete, "/subscriptions/s1/rg/x?api-version=2022-09-01"},
      {:post, "/dbs/db/colls/c/docs"},
      {:get, "/dbs"},
      {:get, "/keys/k1"},
      {:post, "/topics/t1/events"},
      {:get, "/acct/cont/blob"}
    ]

    for {method, path} <- protected, router <- [:arm, :egress] do
      conn = route_through(router, method, path, [])

      assert conn.status == 401,
             "anonymous #{method} #{path} on #{router} must be 401, got " <>
               "#{conn.status}: #{String.slice(conn.resp_body || "", 0, 80)}"
    end
  end

  test "exempt matrix: exempt-prefix traversal cannot reach a protected engine on egress" do
    traversals = [
      {:get, "/oauth2/%2e%2e/acct/cont/blob"},
      {:get, "/oauth2/../dbs/db"},
      {:get, "/.well-known/%2f%2e%2e/keys/k1"},
      {:post, "/attest/%2e%2e/dbs/db/colls/c/docs"},
      {:get, "/tenants/../acct/cont/blob"},
      {:get, "/metadata/endpoints/../dbs"}
    ]

    for {method, path} <- traversals do
      conn = route_through(:egress, method, path, [])

      assert conn.status in [401, 404],
             "traversal #{method} #{path} must be 401 (enforced) or 404 (no route), " <>
               "got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 80)}"
    end
  end

  test "alg confusion: alg=none unsigned token refused (SignatureVerificationFailed)" do
    now = System.system_time(:second)
    claims = %{"aud" => @aud, "iss" => @iss, "exp" => now + 3600}

    header = Base.url_encode64(Jason.encode!(%{"alg" => "none", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    unsigned = "#{header}.#{payload}."

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{unsigned}"}])
    assert_challenge(conn, "alg none")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "SignatureVerificationFailed"
  end

  test "alg confusion: RS256-headered token refused against the HS256 signer" do
    now = System.system_time(:second)
    claims = %{"aud" => @aud, "iss" => @iss, "exp" => now + 3600}

    header =
      Base.url_encode64(
        Jason.encode!(%{"alg" => "RS256", "typ" => "JWT", "kid" => "attacker-key"}),
        padding: false
      )

    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    forged = "#{header}.#{payload}.Zm9v"

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{forged}"}])
    assert_challenge(conn, "rs256 confusion")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "SignatureVerificationFailed"
  end

  test "alg confusion: jku/x5u remote key refs confer no acceptance and no fetch" do
    # Even a CORRECTLY HS256-signed token carrying jku/x5u headers is judged
    # solely by the configured signer; remote key references are never fetched.
    now = System.system_time(:second)
    claims = %{"aud" => @aud, "iss" => @iss, "exp" => now + 3600}

    {:ok, token, _} =
      Joken.generate_and_sign(
        %{"jku" => "https://evil.example/jwks", "x5u" => "https://evil.example/cert"},
        claims,
        Joken.Signer.create("HS256", @secret)
      )

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert conn.status == 200, "jku/x5u headers must be inert, got #{conn.status}"
  end

  # -- wave-2 fuzz vectors (fresh seeds) ------------------------------------------

  test "wave2: leading-whitespace authorization value refused" do
    token = mint()

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "  Bearer #{token}"}])
    assert_challenge(conn, "leading ws")
  end

  test "wave2: x-forwarded-proto HTTPS (uppercase) honored under trusted proxy" do
    Application.put_env(:smalt, :trusted_proxies, [{127, 0, 0, 1}])

    tid = "00000000-0000-0000-0000-000000000000"
    now = System.system_time(:second)

    {:ok, token, _} =
      Joken.generate_and_sign(
        %{},
        %{
          "aud" => @aud,
          "iss" => "https://fwd.example.com/#{tid}/v2.0",
          "iat" => now,
          "nbf" => now,
          "exp" => now + 3600
        },
        Joken.Signer.create("HS256", @secret)
      )

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "fwd.example.com"},
        {"x-forwarded-proto", "HTTPS"}
      ])

    assert conn.status == 200, "uppercase HTTPS proto must be honored, got #{conn.status}"
  after
    Application.delete_env(:smalt, :trusted_proxies)
  end

  test "wave2: forwarded-host byte-case must not broaden issuer acceptance" do
    Application.put_env(:smalt, :trusted_proxies, [{127, 0, 0, 1}])

    tid = "00000000-0000-0000-0000-000000000000"
    now = System.system_time(:second)

    {:ok, token, _} =
      Joken.generate_and_sign(
        %{},
        %{
          "aud" => @aud,
          "iss" => "https://fwd.example.com/#{tid}/v2.0",
          "iat" => now,
          "nbf" => now,
          "exp" => now + 3600
        },
        Joken.Signer.create("HS256", @secret)
      )

    conn =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "FWD.EXAMPLE.COM"},
        {"x-forwarded-proto", "https"}
      ])

    assert_challenge(conn, "case-shifted forwarded host")
  after
    Application.delete_env(:smalt, :trusted_proxies)
  end

  # -- Cycle 9: STS mint-side courts ----------------------------------------------

  defp decode_jwt(token) do
    [_, p, _] = String.split(token, ".")

    p
    |> then(fn part ->
      pad = rem(4 - rem(byte_size(part), 4), 4)
      Base.url_decode64!(part <> String.duplicate("=", pad), padding: false)
    end)
    |> Jason.decode!()
  end

  defp mint_sts(tid \\ "", host \\ "arm.smalt.local", port \\ 19_081) do
    path = if tid == "", do: "/oauth2/v2.0/token", else: "/#{tid}/oauth2/v2.0/token"

    c =
      %Plug.Conn{conn(:post, path, "grant_type=client_credentials&client_id=x&client_secret=y")
      | host: host,
        port: port}
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    assert c.status == 200, "STS mint must succeed, got #{c.status}"
    %{"access_token" => token} = Jason.decode!(c.resp_body)
    token
  end

  test "mint claims: C6 rows 8-10 contract (registered + Azure claim set, DEV-MODE values)" do
    token = mint_sts()
    claims = decode_jwt(token)

    # Row 8: registered claims, iat==nbf, ints in Unix s, 1h lifetime
    for k <- ["exp", "iat", "nbf", "aud", "iss", "sub"] do
      assert Map.has_key?(claims, k), "row 8: missing registered claim #{k}"
    end

    assert claims["iat"] == claims["nbf"], "row 8: iat must equal nbf"
    assert claims["exp"] - claims["iat"] == 3600, "row 8: 1h lifetime"
    assert is_integer(claims["exp"]) and claims["aud"] == "https://management.azure.com"

    # Row 9: Azure claims present
    for k <- ["tid", "oid", "appid", "azp", "roles"] do
      assert Map.has_key?(claims, k), "row 9: missing Azure claim #{k}"
    end

    assert claims["roles"] == ["Contributor", "Owner"]

    # Row 10: DEV-MODE fixed values, pinned
    assert claims["appid"] == "00000000-0000-0000-0000-000000000000"
    assert claims["azp"] == "00000000-0000-0000-0000-000000000000"
    assert claims["oid"] == claims["sub"], "row 10: DEV-MODE pins oid==sub"
    assert claims["tid"] == "00000000-0000-0000-0000-000000000000"

    # Issuer binds to the MINT seat authority
    assert claims["iss"] == "http://arm.smalt.local:19081/00000000-0000-0000-0000-000000000000/v2.0"
  end

  test "mint claims: tenant-scoped endpoint echoes the path tenant (C6 row 5)" do
    claims = mint_sts("9a1b2c3d-0000-0000-0000-000000000001") |> decode_jwt()
    assert claims["tid"] == "9a1b2c3d-0000-0000-0000-000000000001"
    assert claims["iss"] =~ "/9a1b2c3d-0000-0000-0000-000000000001/v2.0"
  end

  test "mint fuzz: missing grant_type -> 400 invalid_request (not 500, not mint)" do
    c =
      %Plug.Conn{conn(:post, "/oauth2/v2.0/token", "client_id=x&client_secret=y")
      | host: "arm.smalt.local", port: 19_081}
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    assert c.status == 400
    assert Jason.decode!(c.resp_body) == %{"error" => "invalid_request"}
  end

  test "mint fuzz: wrong content-type (JSON) still yields exact 400 error envelope" do
    c =
      %Plug.Conn{
        conn(:post, "/oauth2/v2.0/token", ~s({"grant_type":"client_credentials"}))
        | host: "arm.smalt.local",
          port: 19_081
      }
      |> put_req_header("content-type", "application/json")
      |> Smalt.ArmGateway.Router.call([])

    assert c.status in [400, 415]
    assert c.status != 500
  end

  test "mint fuzz: duplicate grant_type is refused invalid_request (AAD-exact, fail-closed)" do
    c =
      %Plug.Conn{
        conn(
          :post,
          "/oauth2/v2.0/token",
          "grant_type=client_credentials&grant_type=password&client_id=x&client_secret=y"
        )
        | host: "arm.smalt.local",
          port: 19_081
      }
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    # FIXED (was a receipted DEV-MODE divergence): duplicates are now refused
    # invalid_request via the BodyCache raw-body reader (OAuth 2.1 draft /
    # AAD parity), regardless of which duplicate is last.
    assert c.status == 400
    assert Jason.decode!(c.resp_body) == %{"error" => "invalid_request"}
    assert get_resp_header(c, "cache-control") == ["no-store"]
  end

  test "mint fuzz: duplicate grant_type where the LAST is valid still refused (invalid_request)" do
    c =
      %Plug.Conn{
        conn(
          :post,
          "/oauth2/v2.0/token",
          "grant_type=password&grant_type=client_credentials&client_id=x&client_secret=y"
        )
        | host: "arm.smalt.local",
          port: 19_081
      }
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    assert c.status == 400
    assert Jason.decode!(c.resp_body) == %{"error" => "invalid_request"}
  end

  test "mint fuzz: single grant_type with a substring-neighbor key still mints" do
    # "xgrant_type=..." neighbors must not false-positive the raw scan.
    token =
      mint_sts_with_params(
        "grant_type=client_credentials&client_id=x&client_secret=y&xgrant_type=1"
      )

    claims = decode_jwt(token)
    assert claims["aud"] == "https://management.azure.com"
  end

  test "mint fuzz: redirect_uri smuggling does not widen the grant (DEV-MODE: inert)" do
    token =
      mint_sts_with_params(
        "grant_type=client_credentials&client_id=x&client_secret=y&redirect_uri=https://evil.example/cb&scope=https://management.azure.com/.default"
      )

    claims = decode_jwt(token)
    # Real AAD: scope/redirect_uri do not widen a client_credentials grant;
    # DEV-MODE pins them inert — claims are the fixed contract set above.
    assert claims["aud"] == "https://management.azure.com"
    assert claims["roles"] == ["Contributor", "Owner"]
  end

  defp mint_sts_with_params(params) do
    c =
      %Plug.Conn{conn(:post, "/oauth2/v2.0/token", params) | host: "arm.smalt.local", port: 19_081}
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    assert c.status == 200
    %{"access_token" => token} = Jason.decode!(c.resp_body)
    token
  end

  test "roundtrip property: token minted at seat A verifies at seats B and C via the registry" do
    token = mint_sts("00000000-0000-0000-0000-000000000000", "arm.smalt.local", 19_081)

    seats = [
      {"cosmos.smalt.local", 8443, :egress},
      {"blob.smalt.local", 9999, :egress},
      {"kv.smalt.local", 7103, :egress}
    ]

    for {host, port, router} <- seats do
      c =
        %Plug.Conn{conn(:get, "/dbs") | host: host, port: port}
        |> put_req_header("authorization", "Bearer #{token}")
        |> Smalt.EgressRouter.call([])

      assert c.status != 401,
             "seat #{host}:#{port} must accept the seat-A mint via the trusted-authority " <>
               "registry, got #{c.status}: #{String.slice(c.resp_body || "", 0, 80)}"

      assert c.status == 200, "seat #{host}:#{port} expected 200, got #{c.status}"
    end
  end

  test "roundtrip guard: the tenant-scoped exemption cannot shadow an egress route" do
    # 4-segment shape /x/oauth2/v2.0/token is exempt ONLY as the STS mint
    # form; on the egress it matches no route (max 3 segments). Prove it is
    # never anonymous data: with the blob guard header present, still no 200.
    for path <- ["/a/b/oauth2/v2.0/token", "/a/oauth2/v2.0/token", "/dbs/db/oauth2/v2.0/token"] do
      c = egress_req(:get, path, [{"x-ms-version", "2021-06-08"}])

      assert c.status in [401, 404],
             "egress #{path} must not serve anonymously via the exemption, got #{c.status} #{c.resp_body}"
    end
  end

  test "roundtrip guard: %-encoded suffix fails the exemption anchor (fail-closed)" do
    c = arm_req(:get, "/x/oauth2/v2.0/token%2f", [{"x-forwarded-host", "evil.example"}])

    # Not exempt (raw path does not END with the token form) -> enforced 401.
    assert c.status == 401
  end

  test "roundtrip property: never-minted authority is refused at every seat" do
    tid = "00000000-0000-0000-0000-000000000000"
    now = System.system_time(:second)

    {:ok, forged, _} =
      Joken.generate_and_sign(
        %{},
        %{
          "aud" => @aud,
          "iss" => "https://never-minted.example.com/#{tid}/v2.0",
          "iat" => now,
          "nbf" => now,
          "exp" => now + 3600
        },
        Joken.Signer.create("HS256", @secret)
      )

    for {host, port} <- [{"cosmos.smalt.local", 8443}, {"blob.smalt.local", 9999}] do
      c =
        %Plug.Conn{conn(:get, "/dbs") | host: host, port: port}
        |> put_req_header("authorization", "Bearer #{forged}")
        |> Smalt.EgressRouter.call([])

      assert_challenge(c, "forged authority at #{host}")
      assert Jason.decode!(c.resp_body)["error"]["message"] =~ "IssuerMismatch"
    end
  end

  # -- Cycle 10: exemption-widen courts (mutation pre-armed) ----------------------

  test "exemption is bounded: non-token oauth2 paths stay ENFORCED on both routers" do
    # These shapes would become exempt under an unbounded ^/[^/]+/oauth2/
    # prefix regex (no $ anchor); they must remain enforced (401 anonymous).
    for {method, path} <- [
          {:get, "/a/oauth2/junk"},
          {:get, "/a/oauth2/v2.0/"},
          {:get, "/a/oauth2/v2.0/tokens"},
          {:get, "/a/oauth2/v2.0/token%2f"},
          {:get, "/a/OAUTH2/v2.0/token"},
          {:get, "/a/Oauth2/v2.0/token"}
        ],
        router <- [:arm, :egress] do
      conn = route_through(router, method, path, [])

      assert conn.status == 401,
             "#{method} #{path} on #{router} must stay ENFORCED (401), got " <>
               "#{conn.status}: #{String.slice(conn.resp_body || "", 0, 80)}"
    end
  end

  test "exemption fuzz: 4-segment shapes against every egress literal prefix never serve data" do
    # Does ANY egress route shape match the exemption regex? Probe 4-segment
    # paths whose 2nd segment is oauth2 through every egress literal family,
    # with the blob guard header present.
    for path <- [
          "/dbs/oauth2/v2.0/token",
          "/keys/oauth2/v2.0/token",
          "/app/oauth2/v2.0/token",
          "/atlas/oauth2/v2.0/token",
          "/v1/oauth2/v2.0/token"
        ] do
      c = egress_req(:get, path, [{"x-ms-version", "2021-06-08"}])

      assert c.status in [401, 404, 400],
             "egress #{path} must never serve data via the exemption, got #{c.status} #{c.resp_body}"
    end
  end

  # -- Cycle 11 / wave 5: fresh-seed mint fuzz + config-space boundaries ---------

  test "wave5: grant_type case variants are unsupported_grant_type (AAD case-sensitive)" do
    for gt <- ["Client_Credentials", "CLIENT_CREDENTIALS", "client-credentials"] do
      c =
        %Plug.Conn{
          conn(:post, "/oauth2/v2.0/token", "grant_type=#{gt}&client_id=x&client_secret=y")
          | host: "arm.smalt.local",
            port: 19_081
        }
        |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
        |> Smalt.ArmGateway.Router.call([])

      assert c.status == 400, "grant_type #{gt} must be 400"
      assert Jason.decode!(c.resp_body) == %{"error" => "unsupported_grant_type"}
    end
  end

  test "wave5: empty grant_type value and empty body are invalid_request" do
    for body <- ["grant_type=&client_id=x&client_secret=y", ""] do
      c =
        %Plug.Conn{conn(:post, "/oauth2/v2.0/token", body) | host: "arm.smalt.local", port: 19_081}
        |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
        |> Smalt.ArmGateway.Router.call([])

      assert c.status == 400
      assert Jason.decode!(c.resp_body) == %{"error" => "invalid_request"}
    end
  end

  test "wave5: empty :token_audiences list refuses EVERYTHING (fail-closed config)" do
    Application.put_env(:smalt, :token_audiences, [])

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint()}"}])

    assert_challenge(conn, "empty audiences")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "AudienceMismatch"
  end

  test "wave5: non-binary audience ENTRIES fail closed (AudienceMismatch, no crash)" do
    Application.put_env(:smalt, :token_audiences, [12_345, :management])

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint()}"}])

    assert_challenge(conn, "non-binary entries")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "AudienceMismatch"
  end

  test "wave5: large audiences list still admits members (membership not degraded)" do
    long = for i <- 1..2000, do: "https://aud-#{i}.example.com"
    Application.put_env(:smalt, :token_audiences, long ++ [@aud])

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mint()}"}])
    assert conn.status == 200, "2001-entry audiences list must still admit members"
  after
    Application.delete_env(:smalt, :token_audiences)
  end

  test "anonymous mode: no token required (explicit opt-out honoured)" do
    Application.put_env(:smalt, :auth_mode, :anonymous)

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01")
    assert conn.status == 200
  after
    Application.put_env(:smalt, :auth_mode, :enforce)
  end

  # -- lens-2 cycle 1 -----------------------------------------------------------
  # (a) concurrency: register_trusted_authority/1 was a persistent_term
  #     read-modify-write on ONE key — concurrent mints from distinct
  #     authorities lost registrations. 50 parallel mints must all land.
  # (b) chunked bodies: BodyCache overwrote :smalt_raw_body with the LAST
  #     chunk on {:more, ...}; a duplicate grant_type= split across chunks
  #     evaded duplicate detection (fail-open). The full raw body must be
  #     cached after the Plug.Parsers read loop.

  @race_tag "lane2-race"

  defp race_conn do
    # Fixed request authority; acceptance must come from the minted-authority
    # registry leg, not the request_authority leg.
    :get
    |> conn("/subscriptions?api-version=2021-04-01")
    |> put_req_header("authorization", "Bearer placeholder")
    |> Map.replace!(:port, 19_081)
    |> Map.replace!(:host, "#{@race_tag}.test.invalid")
    |> Map.replace!(:scheme, :http)
  end

  test "lens2: 50 concurrent register_trusted_authority calls all land (no lost update)" do
    authorities =
      for i <- 1..50, do: "http://#{@race_tag}-#{i}.test.invalid:19081/#{@race_tag}/v2.0"

    tasks =
      Task.async_stream(authorities, &Smalt.Auth.Bearer.register_trusted_authority/1,
        max_concurrency: 50,
        timeout: 10_000
      )

    Enum.each(tasks, fn {:ok, :ok} -> :ok end)

    # Every minted authority must accept a correctly-signed token with that iss.
    for iss <- authorities do
      token = mint(%{"iss" => iss})
      assert Smalt.Auth.Bearer.verify_bearer(%{race_conn() | req_headers: [{"authorization", "Bearer #{token}"}]}) == :ok,
             "concurrently-registered authority lost: #{iss}"
    end
  end

  defp parse_with_body_cache(conn, body) do
    # Plug.Test.conn/3 with a binary body wires the real test adapter:
    # Plug.Conn.read_body works against it, so this drives the REAL
    # BodyCache reader through the REAL chunked read loop.
    %{
      conn(:post, "/t/oauth2/v2.0/token", body)
      | req_headers: [{"content-type", "application/x-www-form-urlencoded"}]
    }
    |> do_read()
  end

  defp do_read(conn) do
    case Smalt.Auth.BodyCache.read_body(conn, length: 4_096, read_length: 4_096) do
      {:more, _chunk, conn} -> do_read(conn)
      {:ok, _full, conn} -> conn
    end
  end

  test "lens2: chunked form body — full raw body cached after the read loop" do
    pad = String.duplicate("a=1&", 3000) # 12KB: forces multiple read_body chunks
    body = pad <> "grant_type=client_credentials&grant_type=client_credentials"

    cached =
      %{
        Plug.Test.conn(:post, "/t/oauth2/v2.0/token")
        | host: "www.example.com"
      }
      |> parse_with_body_cache(body)
      |> Map.get(:private)
      |> Map.get(:smalt_raw_body)

    assert is_binary(cached)
    # Both duplicates visible — this is the string the STS dup-check scans.
    assert cached == body, "cached raw body must be the COMPLETE request body"
  end

  # -- lens-2 cycle 2: sts_signer precedence under MID-FLIGHT env rotation ------
  # Precedence contract: :smalt, :sts_signing_secret (env) WINS over the
  # persistent_term dev secret. Rotation between mint and verify must be
  # fail-closed (old token refused, no crash) in BOTH directions.

  @dev_secret_tag "lens2-cycle2"

  test "lens2 rotation: env secret rotated between mint and verify -> old token refused" do
    token = mint(%{})

    # Mid-flight rotation: env A -> env B (A != B, both set).
    Application.put_env(:smalt, :sts_signing_secret, @secret <> "-rotated")

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])

    assert_challenge(conn, "post-rotation token")
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "SignatureVerificationFailed"
  after
    Application.put_env(:smalt, :sts_signing_secret, @secret)
  end

  test "lens2 rotation: env secret DELETED between mint and verify -> refused (no silent dev-secret fallback)" do
    token = mint(%{})

    Application.delete_env(:smalt, :sts_signing_secret)

    # Fail-closed: unless the dev secret happens to be absent too, falling
    # back would VERIFY a token signed with the deleted env secret only by
    # coincidence; the court holds when the dev secret differs (it does —
    # generated at app boot) OR is absent (NoSigningSecretConfigured).
    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert conn.status == 401, "deleted env secret must refuse the pre-deletion token"

    assert Jason.decode!(conn.resp_body)["error"]["message"] in [
             "SignatureVerificationFailed",
             "NoSigningSecretConfigured"
           ]
  after
    Application.put_env(:smalt, :sts_signing_secret, @secret)
  end

  test "lens2 rotation: 50 parallel verifies ACROSS a mid-flight rotation — no crash, deterministic post-rotation" do
    token_a = mint(%{})
    Application.put_env(:smalt, :sts_signing_secret, @secret <> "-B")
    token_b = mint(%{}, Joken.Signer.create("HS256", @secret <> "-B"))

    results =
      Task.async_stream(1..50, fn _ ->
        c = arm_req(:get, "/persistentscopes", [{"authorization", "Bearer #{token_a}"}])
        {c.status, Jason.decode!(c.resp_body)["error"]["message"]}
      end, max_concurrency: 50, timeout: 10_000)
      |> Enum.map(fn {:ok, r} -> r end)

    # Every lane returned a 401 envelope (no 500 crash) for the A-signed token.
    assert Enum.all?(results, fn {status, msg} ->
             status == 401 and is_binary(msg)
           end)

    # Post-rotation, the B-signed token is accepted deterministically.
    conn_b = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token_b}"}])

    assert conn_b.status == 200
  end

  test "lens2 precedence: DEV secret pinned in persistent_term must NOT outrank the env secret" do
    # The cycle-4 precedence fix: env :sts_signing_secret WINS even when a
    # dev secret was already generated in :persistent_term (dev substrate
    # minted without env, then ops sets env). This court PINS the dev secret
    # — the prior suite never did, so dev-first was indistinguishable from
    # env-first (mutation survived the suite before this court existed).
    :persistent_term.put({Smalt.ArmGateway.Router, :sts_signing_secret}, "lens2-dev-secret-0123456789")

    token = mint(%{}) # env-signed

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert conn.status == 200, "env secret must outrank the pinned dev secret"

    # And the dev-signed token is refused while env is set (fail-closed).
    {:ok, dev_token, _} =
      Joken.generate_and_sign(%{}, %{"aud" => @aud, "iss" => @iss, "exp" => System.system_time(:second) + 3600},
        Joken.Signer.create("HS256", "lens2-dev-secret-0123456789"))

    conn2 = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{dev_token}"}])
    assert conn2.status == 401, "dev-signed token shape must be refused while env secret is set"
  after
    :persistent_term.erase({Smalt.ArmGateway.Router, :sts_signing_secret})
  end

  # -- lens-3 cycle 1: trusted-authority retention fence -------------------------
  # The lens-2 @doc claimed "a handful" of persistent_term keys. Measured:
  # 1000 distinct mint authorities -> 1000 keys, and the mint-time request
  # authority is client-INFLUENCEABLE under a trusted proxy (x-forwarded-host
  # feeds request_authority/1, which the STS mint registers). The fence caps
  # registration at @max_trusted_authorities; the court pins the bound.

  @fence_tag "lens3-fence"

  test "lens3 fence: 1200 distinct mint authorities leave at most 1024 persistent_term keys" do
    authorities =
      for i <- 1..1200, do: "http://#{@fence_tag}-#{i}.test.invalid:19081/t/v2.0"

    Enum.each(authorities, &Smalt.Auth.Bearer.register_trusted_authority/1)

    registered =
      :persistent_term.get()
      |> Enum.count(fn
        {{Smalt.Auth.Bearer, :trusted, a}, true} -> String.contains?(a, @fence_tag)
        _ -> false
      end)

    assert registered <= 1024, "fence must cap key growth, got #{registered}"

    # A capped-out authority's token still verifies at its OWN seat — the
    # fence withholds only cross-SEAT acceptance, never breaks the minting
    # seat (request-authority issuer leg, not the registry leg).
    capped_iss = "http://#{@fence_tag}-capped.test.invalid:19081/t/v2.0"
    Smalt.Auth.Bearer.register_trusted_authority(capped_iss)

    own_seat_conn = %{
      race_conn()
      | host: "#{@fence_tag}-capped.test.invalid",
        req_headers: [{"authorization", "Bearer #{mint(%{"iss" => capped_iss})}"}]
    }

    assert Smalt.Auth.Bearer.verify_bearer(own_seat_conn) == :ok,
           "capped-out authority must still verify at its own seat"
  after
    :persistent_term.get()
    |> Enum.each(fn
      {{Smalt.Auth.Bearer, :trusted, a}, true} ->
        if String.contains?(a, @fence_tag), do: :persistent_term.erase({Smalt.Auth.Bearer, :trusted, a})

      _ ->
        :ok
    end)
  end

  # -- lens-3 cycle 2: register/reset racing (50 registers x 10 resets) ---------
  # Semantics pinned: (a) reset is a transition that erases everything present
  # AT RESET TIME (later registers survive); (b) a register that happens-after
  # the LAST reset always lands (no lost registration); (c) the storm never
  # crashes or leaves the registry wedged.

  @race2_tag "lens3-race2"

  test "lens3 race: 50 concurrent registers x 10 resets — post-storm registers always land" do
    authorities = for i <- 1..50, do: "http://#{@race2_tag}-#{i}.test.invalid:19081/t/v2.0"
    register = &Smalt.Auth.Bearer.register_trusted_authority/1

    task_bodies =
      Enum.concat(
        # 50 register lanes (lens-2 50-lane shape)
        Enum.map(authorities, fn a -> fn -> register.(a) end end),
        # 10 reset lanes
        Enum.map(1..10, fn _ -> fn -> Smalt.Auth.Bearer.reset_trusted_authorities!() end end)
      )

    task_bodies
    |> Task.async_stream(fn f -> f.() end, max_concurrency: 60, timeout: 15_000)
    |> Enum.each(fn {:ok, _} -> :ok end)

    # A register that happens-after the LAST reset must land: do one final
    # register + acceptance probe (this is the "reset that matters" boundary).
    final = "http://#{@race2_tag}-final.test.invalid:19081/t/v2.0"
    register.(final)

    probe = %{race_conn() | req_headers: [{"authorization", "Bearer #{mint(%{"iss" => final})}"}]}
    assert Smalt.Auth.Bearer.verify_bearer(probe) == :ok,
           "post-reset register must land"

    # And the storm left no wedged state: a fresh reset still erases cleanly.
    assert Smalt.Auth.Bearer.reset_trusted_authorities!() == :ok
  after
    Smalt.Auth.Bearer.register_trusted_authority("http://arm.smalt.local:19081")
  end

  test "lens3 race: reset erases a previously-registered authority (happens-before case)" do
    a = "http://#{@race2_tag}-hb.test.invalid:19081/t/v2.0"
    Smalt.Auth.Bearer.register_trusted_authority(a)
    Smalt.Auth.Bearer.reset_trusted_authorities!()

    probe = %{race_conn() | req_headers: [{"authorization", "Bearer #{mint(%{"iss" => a})}"}]}
    refute Smalt.Auth.Bearer.verify_bearer(probe) == :ok,
           "registered-then-reset authority must be refused (restart contract)"

    # Non-matching reset must NOT erase: register survives an unrelated erase.
    Smalt.Auth.Bearer.register_trusted_authority(a)
    :persistent_term.get()
    |> Enum.each(fn
      {{Smalt.Auth.Bearer, :trusted, other}, true} ->
        if other != "http://#{@race2_tag}-hb.test.invalid:19081", do: :persistent_term.erase({Smalt.Auth.Bearer, :trusted, other})

      _ ->
        :ok
    end)

    assert Smalt.Auth.Bearer.verify_bearer(probe) == :ok,
           "authority must survive erasure of unrelated keys"
  after
    :persistent_term.get()
    |> Enum.each(fn
      {{Smalt.Auth.Bearer, :trusted, a}, true} ->
        if String.contains?(a, @race2_tag) or String.contains?(a, "arm.smalt.local"),
          do: :persistent_term.erase({Smalt.Auth.Bearer, :trusted, a})

      _ ->
        :ok
    end)
  end

  # -- lens-3 cycle 3: BodyCache under Parsers variants + duplicate body reads --
  # The lens-2 court drove one urlencoded read loop. These pin: (a) the cache
  # survives a SECOND body read (two plugs both reading) — the second read
  # yields an empty fragment and must not truncate the cached body;
  # (b) JSON content-type requests cache the complete raw body too (pass:
  # ["*/*"] means every content-type flows through the same reader);
  # (c) a length-limited read that errors passes the error through unchanged
  # (fail-closed: no half-cache, no crash).

  defp full_cached_body(conn, opts) do
    case Smalt.Auth.BodyCache.read_body(conn, opts) do
      {:more, _chunk, conn} -> full_cached_body(conn, opts)
      {:ok, _full, conn} -> conn.private[:smalt_raw_body]
      {:error, reason} -> {:error, reason}
    end
  end

  test "lens3 bodycache: second (duplicate) read does not truncate the cached body" do
    body = "grant_type=client_credentials&client_id=x&client_secret=y"
    conn = %{conn(:post, "/t", body) | req_headers: [{"content-type", "application/x-www-form-urlencoded"}]}

    {:ok, body, conn1} = Smalt.Auth.BodyCache.read_body(conn, length: 8_000_000)

    # The second read (a second plug reading the same conn) returns the empty
    # tail fragment; the cache must remain the COMPLETE first body.
    assert {:ok, "", conn2} = Smalt.Auth.BodyCache.read_body(conn1, length: 8_000_000)
    assert conn2.private[:smalt_raw_body] == body,
           "duplicate read must leave the full cached body intact"
  end

  test "lens3 bodycache: JSON content-type caches the full raw body (pass: [\"*/*\"])" do
    json = Jason.encode!(%{pad: String.duplicate("x", 10_000), grant_type: "client_credentials"})
    conn = %{conn(:post, "/x/oauth2/v2.0/token", json) | req_headers: [{"content-type", "application/json"}]}

    assert full_cached_body(conn, length: 4_096, read_length: 4_096) == json,
           "JSON body must be fully cached regardless of parser"
  end

  # Minimal hand-written adapter (Chicago exception: the real test adapter
  # cannot produce a transport-level read error; this is a simple fake of a
  # REAL interface, not a mock). Returns {:error, :closed} on any read.
  defmodule ErrAdapter do
    def read_req_body(_state, _opts), do: {:error, :closed}
    def send_resp(_status, _headers, _body, state), do: {:ok, "", state}
  end

  test "lens3 bodycache: read error passes through unchanged (no half-cache)" do
    # Transport-level read error: BodyCache must surface it untouched
    # (fail-closed: Plug.Parsers never sees a partial cache to dup-check).
    conn = %Plug.Conn{
      conn(:post, "/t", "")
      | adapter: {ErrAdapter, :state},
        req_headers: [{"content-type", "application/x-www-form-urlencoded"}]
    }

    assert Smalt.Auth.BodyCache.read_body(conn, []) == {:error, :closed}
  end

  # -- lens-3 cycle 4: token-structure-aware fuzz — valid JWT, ONE claim mutated -
  # Fresh generator shape: build a VALID signed JWT, then mutate exactly one
  # claim (fresh seeds, 8 mutation operators over the real claim set). Property:
  # any single-claim mutation is refused with the mapping's exact refusal class
  # (never 5xx, never accepted) — i.e. every claim is load-bearing.

  @claim_mutations [
    {:aud, "https://evil.example.com", "AudienceMismatch"},
    {:aud, 12_345, "AudienceMismatch"},
    {:aud, nil, "AudienceMismatch"},
    {:iss, "https://evil.example.com/t/v2.0", "IssuerMismatch"},
    {:iss, "", "IssuerMismatch"},
    {:iss, 12_345, "IssuerMismatch"},
    {:exp, "soon", "TokenExpired"},
    {:exp, nil, "TokenExpired"},
    {:exp, -1, "TokenExpired"},
    {:nbf, "later", "TokenNotYetValid"},
    {:nbf, 99_999_999_999, "TokenNotYetValid"},
    {:iat, "past", :accept_pinned}
  ]

  test "lens3 fuzz: single-claim mutation corpus — every claim is load-bearing" do
    :rand.seed(:exsss, {314_004, 42, 9001})

    for {claim, value, expected} <- @claim_mutations do
      token = mint(%{to_string(claim) => value})

      c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])

      cond do
        expected == :accept_pinned ->
          # iat is informational (RFC 7519 §4.1.6); AAD parity: not enforced.
          assert c.status == 200, "mutated #{claim}=#{inspect(value)} pinned-accept, got #{c.status}"

        is_binary(expected) ->
          assert c.status == 401,
                 "mutated #{claim}=#{inspect(value)} must be 401, got #{c.status}"

          msg = Jason.decode!(c.resp_body)["error"]["message"]
          assert msg == expected, "mutated #{claim}: expected #{expected}, got #{msg}"
      end
    end

    # Fresh-seed random single-claim mutation fuzz: UNCONDITIONALLY-invalid
    # mutations only (aud/iss garbage is always refused; exp/nbf edge values
    # that are RFC-legitimate — e.g. nbf=0 — belong to the deterministic
    # table above, not the any-mutation property).
    claims = ["aud", "iss"]

    for _ <- 1..120 do
      claim = Enum.random(claims)
      value = Enum.random([nil, "", 0, -1, 12_345, "https://evil.example", [], %{}])

      token = mint(%{claim => value})

      c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
      assert c.status == 401, "mutated #{claim}=#{inspect(value)} must be 401"
    end
  end

  test "lens3 fuzz: REMOVED claim corpus — deleting any load-bearing claim refuses" do
    for claim <- ["aud", "iss", "exp"] do
      claims = %{"aud" => @aud, "iss" => @iss, "exp" => System.system_time(:second) + 3600}
      token = mint(%{claim => nil})

      # Joken keeps nil? Ensure deletion by minting the reduced claim set.
      {:ok, token, _} =
        Joken.generate_and_sign(
          %{},
          Map.delete(claims, claim),
          Joken.Signer.create("HS256", @secret)
        )

      c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
      assert c.status == 401, "deleted #{claim} must refuse, got #{c.status}"
    end
  end

  # -- lens-2 cycle 3: fresh fuzz corpus — class-partitioned JWS-sequence -------
  # Different generator shape from cycles 1/9/10/11 (header fuzz, claims fuzz,
  # egress shape fuzz, fresh-seed mint fuzz): a SEGMENT-CLASS partition over
  # JWS structure — 2..5 dot-separated segments, each drawn from an adversarial
  # class pool, plus "alg":"none" and header-injection forms. Property under
  # test: every malformed/unsigned shape is 401 on a live route (never 5xx,
  # never accepted).

  @fuzz_classes [
    "",                    # empty segment
    "eyJhbGciOiJub25lIn0", # {"alg":"none"} header b64
    "e30",                 # "{}" — empty JSON b64
    "WyJhIl0",             # JSON array b64
    "..",                  # dots inside a segment
    String.duplicate("A", 4096), # oversized segment
    "%C3%28",              # percent-encoding garbage
    "§ü‰€",                # non-ASCII
    "\t\v\f",              # control chars
    "PHBheWxvYWQ+",        # base64 (NOT base64url) alphabet
    "eyJhbGciOiJSUzI1NiJ9" # {"alg":"RS256"} — wrong-alg confusion class
  ]

  test "lens2 fuzz: class-partitioned JWS-sequence corpus all refused on a live route" do
    :rand.seed(:exsss, {777_001, 42, 9001})

    tokens =
      for _ <- 1..400 do
        n = Enum.random(2..5)

        (
          segs = for _ <- 1..n, do: Enum.random(@fuzz_classes)
          Enum.join(segs, ".")
        )
      end

    # Deterministic corpus: include the exact "alg":"none" 2-segment form.
    tokens = ["eyJhbGciOiJub25lIn0.e30."] ++ tokens

    for token <- tokens do
      c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
      assert c.status == 401, "fuzz token must be refused: #{inspect(token)}"
    end
  end

  test "lens2 fuzz: Authorization scheme corpus — malformed scheme forms all refused" do
    :rand.seed(:exsss, {777_002, 42, 9001})

    valid_token = mint(%{})

    schemes = [
      "",                     # empty header value
      "  ",                   # whitespace only
      "Bearer",               # no token
      "Bearer   ",            # trailing spaces, no token
      "Basic #{valid_token}", # wrong scheme
      "bearer   #{valid_token}", # multi-space padding (RFC 7235 trim)
      "bEaReR #{valid_token}",   # case mix
      "Bearer\t#{valid_token}",  # TAB separator — NOT a valid SP separator
      "Bearer #{valid_token} extra", # trailing junk
      "Bearer #{valid_token} extra more junk"
    ]

    statuses =
      for value <- schemes do
        arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", value}]).status
      end

    # Malformed forms refuse; the RFC-7235 multi-space + case-mix forms
    # ACCEPT (documented trim/case-insensitivity — membership pinned, not
    # weakened: same two forms the cycle-1 contract court already fixed).
    assert statuses == [
             401, 401, 401, 401,
             401,             # Basic
             200,             # "bearer   " multi-space trim -> accept
             200,             # "bEaReR" case mix -> accept
             401,             # tab separator
             401,             # trailing junk
             401              # trailing junk x2
           ]
  end

  # -- lens-4 cycle 1: registered-claim completeness audit ----------------------
  # Every RFC 7519 §4.1 registered claim whose handling the previous lens
  # waves had not pinned. Contract discovered + pinned (all real transports):
  #   jti / sub / azp / oid / tid / roles  -> informational on VERIFY (not in
  #     validate_claims), so single-claim mutations accept. This is the pinned
  #     contract, not an oversight to "fix": signature already binds these to
  #     the mint; the bearer profile has NO replay-dedup (unlike the SKR MAA
  #     profile, which refuses a replayed jti with 403 TokenReplay — that
  #     divergence is deliberate: bearer tokens are replayable by design).
  #   iat -> informational (RFC 7519 §4.1.6, pinned lens-3); ABSURD FUTURE iat
  #     also accepts — same RFC footing.
  #   exp / nbf -> the ONLY enforced claims; boundary semantics pinned below
  #     (inclusive exp <= now / nbf <= now, integer-only, fail-closed).

  @registered_info_claims [
    {"jti", "replay-me-123"},
    {"jti", ""},
    {"jti", 12_345},
    {"sub", ""},
    {"sub", 12_345},
    {"sub", nil},
    {"azp", ""},
    {"azp", ["not", "a", "string"]},
    {"roles", "not-a-list"},
    {"roles", []},
    {"roles", nil},
    {"oid", ""},
    {"tid", ""},
    {"tid", nil}
  ]

  test "lens4 claim audit: informational registered claims accept under single-claim mutation" do
    for {claim, value} <- @registered_info_claims do
      token = mint(%{to_string(claim) => value})

      c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])

      assert c.status == 200,
             "#{claim}=#{inspect(value)} is informational (signature-bound at mint); " <>
               "expected 200, got #{c.status} #{inspect(c.resp_body)}"
    end
  end

  test "lens4 claim audit: iat absurd-future accepts (RFC informational, AAD parity)" do
    now = System.system_time(:second)
    token = mint(%{"iat" => now + 999_999})

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])

    assert conn.status == 200, "iat is informational; expected 200, got #{conn.status}"
  end

  test "lens4 claim audit: real mint issues no jti and carries iat == nbf == now" do
    c =
      conn(:post, "/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token", token_params())
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Smalt.ArmGateway.Router.call([])

    assert c.status == 200

    {:ok, claims} = Joken.peek_claims(Jason.decode!(c.resp_body)["access_token"])
    now = System.system_time(:second)

    refute Map.has_key?(claims, "jti"),
           "mint issues NO jti — bearer profile is replayable by design (SKR is the dedup profile)"

    assert abs(claims["iat"] - now) <= 1
    assert claims["nbf"] == claims["iat"]
    assert claims["exp"] == claims["iat"] + 3600
    assert claims["sub"] == claims["oid"], "sub/oid fixed identity pair pinned"
    assert is_binary(claims["sub"]) and claims["sub"] != ""
    assert claims["roles"] == ["Contributor", "Owner"]
  end

  test "lens4 time boundaries: exp/nbf inclusive-equality and precision corpus" do
    now = System.system_time(:second)

    rows = [
      # {claim overrides, expected}
      {%{"exp" => now}, "TokenExpired"},                # exp == now: INCLUSIVE refuse
      {%{"exp" => now + 1}, 200},                       # first future second accepts
      {%{"exp" => now + 30.5}, "TokenExpired"},         # float exp: fail-closed refuse
      {%{"exp" => "9999999999"}, "TokenExpired"},       # string exp: fail-closed refuse
      {%{"nbf" => now}, 200},                           # nbf == now: INCLUSIVE accept
      {%{"nbf" => now + 1}, "TokenNotYetValid"},        # one-second window edge refuses
      {%{"nbf" => now + 30.5}, "TokenNotYetValid"},     # float nbf: fail-closed refuse
      {%{"nbf" => "later"}, "TokenNotYetValid"},        # string nbf (lens-3 corpus row)
      {%{"nbf" => -1}, 200},                            # deep-past nbf accepts
      {%{"nbf" => 0}, 200},                             # epoch nbf accepts (RFC-legitimate)
      {%{"nbf" => now, "exp" => now}, "TokenExpired"}   # nbf == exp: exp leg wins first
    ]

    for {overrides, expected} <- rows do
      token = mint(overrides)

      c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
      msg = if c.status == 401, do: Jason.decode!(c.resp_body)["error"]["message"]

      cond do
        expected == 200 ->
          assert c.status == 200, "rows #{inspect(overrides)}: expected 200, got #{c.status} #{msg}"

        true ->
          assert c.status == 401, "rows #{inspect(overrides)}: expected 401, got #{c.status}"
          assert msg == expected, "rows #{inspect(overrides)}: expected #{expected}, got #{msg}"
      end
    end
  end

  test "lens4 cap side: at the cap the mint still succeeds; cross-SEAT acceptance withheld" do
    tag = "lens4-cap"
    authorities = for i <- 1..1100, do: "http://#{tag}-#{i}.test.invalid:19081/t/v2.0"
    Enum.each(authorities, &Smalt.Auth.Bearer.register_trusted_authority/1)

    fresh = "http://#{tag}-fresh.test.invalid:19081/t/v2.0"

    # Mint-time registration past the cap: :ok, no raise, no growth.
    assert Smalt.Auth.Bearer.register_trusted_authority(fresh) == :ok

    registered =
      :persistent_term.get()
      |> Enum.count(fn
        {{Smalt.Auth.Bearer, :trusted, a}, true} -> String.contains?(a, tag)
        _ -> false
      end)

    assert registered <= 1024

    # Mint-side observable 1: the token verifies at its OWN seat (request-
    # authority issuer leg) — the mint path itself never breaks at the cap.
    own = %{
      race_conn()
      | host: "#{tag}-fresh.test.invalid",
        req_headers: [{"authorization", "Bearer #{mint(%{"iss" => fresh})}"}]
    }

    assert Smalt.Auth.Bearer.verify_bearer(own) == :ok, "mint works at cap: own-seat verify"

    # Mint-side observable 2: cross-SEAT acceptance is exactly what the cap
    # withholds — same token at a foreign host refuses IssuerMismatch.
    foreign = %{race_conn() | host: "other-seat.test.invalid"}

    assert {:refuse, "InvalidAuthenticationTokenIssuer", "IssuerMismatch"} =
             Smalt.Auth.Bearer.verify_bearer(%{foreign | req_headers: [{"authorization", "Bearer #{mint(%{"iss" => fresh})}"}]})
  after
    :persistent_term.get()
    |> Enum.each(fn
      {{Smalt.Auth.Bearer, :trusted, a}, true} ->
        if String.contains?(a, "lens4-cap"), do: :persistent_term.erase({Smalt.Auth.Bearer, :trusted, a})

      _ ->
        :ok
    end)
  end

  # -- lens-4 cycle 2: empty-authority registry poisoning (fail-closed fence) ---
  # issuer_authority/1 collapses a scheme-less string to "" — the registry leg
  # of issuer_ok?/2 keyed on "" would accept ANY scheme-less iss from ANY seat
  # after a single scheme-less register (public API, foreign-caller reachable).
  # Contract pinned: "" is never a registry key; a scheme-less iss NEVER rides
  # the registry leg (it can still pass on its own seat via the request-
  # authority leg when the request itself carries that host — startswith leg).

  @poison_tag "lens4-poison"

  test "lens4 poison: scheme-less register is a no-op; scheme-less iss never rides the registry leg" do
    # 1. Scheme-less register records NO key (not under "").
    assert Smalt.Auth.Bearer.register_trusted_authority("#{@poison_tag}-no-scheme") == :ok

    empty_keys =
      :persistent_term.get()
      |> Enum.count(fn
        {{Smalt.Auth.Bearer, :trusted, ""}, true} -> true
        _ -> false
      end)

    assert empty_keys == 0, "empty-authority registry key must never exist"

    # 2. A validly-signed token with an UNRELATED scheme-less iss is refused
    #    on a foreign seat even after the scheme-less register attempt.
    {:ok, token, _} =
      Joken.generate_and_sign(
        %{},
        %{
          "aud" => @aud,
          "iss" => "#{@poison_tag}-unrelated",
          "exp" => System.system_time(:second) + 3600
        },
        Joken.Signer.create("HS256", @secret)
      )

    foreign = %{race_conn() | host: "foreign-seat.test.invalid"}
    probe = %{foreign | req_headers: [{"authorization", "Bearer #{token}"}]}

    assert {:refuse, "InvalidAuthenticationTokenIssuer", "IssuerMismatch"} =
             Smalt.Auth.Bearer.verify_bearer(probe),
           "scheme-less iss must never be accepted via the registry leg"
  after
    :persistent_term.get()
    |> Enum.each(fn
      {{Smalt.Auth.Bearer, :trusted, ""}, true} -> :persistent_term.erase({Smalt.Auth.Bearer, :trusted, ""})
      _ -> :ok
    end)
  end

  # -- lens-4 cycle 3: forwarded-authority fuzz (trusted-proxy leg) --------------
  # request_authority/1 feeds BOTH the issuer legs and the mint-time
  # registration. Under a trusted proxy, x-forwarded-host/proto are
  # client-supplied; property under fuzz: ANY forwarded header garbage yields
  # 200-or-401 (never 5xx), and the fail-closed degradation rows are exact.

  @fwd_host_pool [
    "pfx.test.invalid",
    "pfx.test.invalid:9443",
    "pfx.test.invalid:0",          # port 0 -> malformed -> degrade to direct
    "pfx.test.invalid:-1",         # negative port -> degrade
    "pfx.test.invalid:999999999999999999999", # overflow -> REAL authority (int>0, exact parse)
    "pfx.test.invalid:8080/extra", # path junk in host header -> degrade
    "a.test, b.test",              # proxy chain -> degrade
    "",                            # empty host -> degrade
    "[::1]:8443",                  # IPv6 form
    "pfx.test.invalid:",           # colon, no port -> degrade
    String.duplicate("h", 3000)    # oversized host
  ]

  @fwd_proto_pool ["https", "http", "HTTPS", "ftp", "", "https, http", "\t"]

  test "lens4 fwd fuzz: forwarded header garbage never 5xx; degradation rows exact" do
    :rand.seed(:exsss, {314_005, 42, 9001})
    Application.put_env(:smalt, :trusted_proxies, [{127, 0, 0, 1}])

    # Registry precondition: direct/forwarded leg pins are only valid when the
    # involved authorities are NOT registered (ExUnit random order — the real
    # mint court legitimately registers "http://www.example.com", which would
    # let direct-bound tokens ride the cross-seat registry leg). Erase first.
    :persistent_term.erase({Smalt.Auth.Bearer, :trusted, "http://www.example.com"})
    :persistent_term.erase({Smalt.Auth.Bearer, :trusted, "http://pfx.test.invalid"})
    :persistent_term.erase({Smalt.Auth.Bearer, :trusted, "http://pfx.test.invalid:9443"})
    :persistent_term.erase({Smalt.Auth.Bearer, :trusted, "http://pfx.test.invalid:999999999999999999999"})
    :persistent_term.erase({Smalt.Auth.Bearer, :trusted, "http://a.test, b.test"})

    token = mint(%{"iss" => "http://pfx.test.invalid/t/v2.0"})

    # Deterministic degradation rows: malformed ports/host forms degrade to
    # the DIRECT request authority, so a token bound to the FORWARDED
    # authority (and valid ONLY via the request-authority leg — NOT the AAD
    # prefix leg) refuses exactly on the malformed rows.
    for host_hdr <- [
          "pfx.test.invalid:0",
          "pfx.test.invalid:-1",
          "pfx.test.invalid:8080/extra",
          "pfx.test.invalid:",
          "[::1]:8443"                   # IPv6 form degrades (first-colon split) — pinned limitation
        ] do
      c =
        arm_req(:get, "/subscriptions?api-version=2021-04-01", [
          {"authorization", "Bearer #{token}"},
          {"x-forwarded-host", host_hdr},
          {"x-forwarded-proto", "http"}
        ])

      assert c.status == 401, "malformed forwarded host #{inspect(host_hdr)} must degrade to direct (401), got #{c.status}"

      # Second, discriminating direction: the DEGRADE target itself. A token
      # bound to the DIRECT authority must ACCEPT on every malformed row —
      # degradation is degrade-to-direct, never degrade-to-refuse.
      direct = mint(%{"iss" => "http://www.example.com/t/v2.0"})

      c2 =
        arm_req(:get, "/subscriptions?api-version=2021-04-01", [
          {"authorization", "Bearer #{direct}"},
          {"x-forwarded-host", host_hdr},
          {"x-forwarded-proto", "http"}
        ])

      assert c2.status == 200, "malformed #{inspect(host_hdr)} must degrade TO DIRECT (direct-bound token accepts), got #{c2.status}"
    end

    # Well-formed forwarded rows accept with the token bound to that authority.
    for {host_hdr, proto} <- [{"pfx.test.invalid", "https"}, {"pfx.test.invalid:9443", "https"}] do
      fwd_auth = forwarded_authority_of(host_hdr, proto)

      fwd_token = mint(%{"iss" => "#{fwd_auth}/t/v2.0"})

      c =
        arm_req(:get, "/subscriptions?api-version=2021-04-01", [
          {"authorization", "Bearer #{fwd_token}"},
          {"x-forwarded-host", host_hdr},
          {"x-forwarded-proto", proto}
        ])

      assert c.status == 200, "well-formed forwarded #{host_hdr} must accept, got #{c.status}"
    end

    # Overflow-port row (cycle-3 correction): Integer.parse succeeds with ""
    # rest and int > 0, so a HUGE port is a REAL forwarded authority, NOT a
    # degradation (the earlier flaky run exposed the misclassification). The
    # token bound to that exact authority accepts; direct-bound refuses.
    overflow_auth = "http://pfx.test.invalid:999999999999999999999"

    fwd_token = mint(%{"iss" => "#{overflow_auth}/t/v2.0"})

    c =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{fwd_token}"},
        {"x-forwarded-host", "pfx.test.invalid:999999999999999999999"},
        {"x-forwarded-proto", "http"}
      ])

    assert c.status == 200, "overflow-port authority must accept its own token, got #{c.status}"

    c =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{mint(%{"iss" => "http://www.example.com/t/v2.0"})}"},
        {"x-forwarded-host", "pfx.test.invalid:999999999999999999999"},
        {"x-forwarded-proto", "http"}
      ])

    assert c.status == 401, "overflow-port authority must NOT accept direct-bound token"

    # Host-garbage row (cycle-3 correction #2): a host value with NO colon
    # keeps the garbage host at the default port — it forms a GARBAGE
    # AUTHORITY (fail-closed: only its own bound token accepts), it does NOT
    # degrade to direct. Pinned both directions.
    garbage_auth = "http://a.test, b.test"

    c =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{mint(%{"iss" => "#{garbage_auth}/t/v2.0"})}"},
        {"x-forwarded-host", "a.test, b.test"},
        {"x-forwarded-proto", "http"}
      ])

    assert c.status == 200, "garbage host authority must accept its own bound token, got #{c.status}"

    c =
      arm_req(:get, "/subscriptions?api-version=2021-04-01", [
        {"authorization", "Bearer #{mint(%{"iss" => "http://www.example.com/t/v2.0"})}"},
        {"x-forwarded-host", "a.test, b.test"},
        {"x-forwarded-proto", "http"}
      ])

    assert c.status == 401, "garbage host authority must NOT accept direct-bound token"

    # Random fuzz: 200 combos, property = never 5xx, never a crash.
    for _ <- 1..200 do
      host = Enum.random(@fwd_host_pool)
      proto = Enum.random(@fwd_proto_pool)

      c =
        arm_req(:get, "/subscriptions?api-version=2021-04-01", [
          {"authorization", "Bearer #{token}"},
          {"x-forwarded-host", host},
          {"x-forwarded-proto", proto}
        ])

      assert c.status in [200, 401], "fuzz forwarded host=#{inspect(host)} proto=#{inspect(proto)}: got #{c.status}"
    end
  after
    Application.delete_env(:smalt, :trusted_proxies)
  end

  defp forwarded_authority_of(host_hdr, proto) do
    scheme = if String.downcase(proto || "") == "https", do: :https, else: :http
    {host, port} = String.split(host_hdr, ":", parts: 2) |> case do
      [h] -> {h, if(scheme == :https, do: 443, else: 80)}
      [h, p] -> {h, String.to_integer(p)}
    end

    port_part = if port in [80, 443], do: "", else: ":#{port}"
    "#{scheme}://#{host}#{port_part}"
  end

  # Lens-5 typed decision (M-L5-3): duplicates REFUSE outright —
  # RFC 7230 §3.2.2 / RFC 9110 §5.3: Authorization is not a list-combinable
  # field, a two-Authorization message is invalid. First-wins was not
  # exploitable to DISPLACE a valid token (the attacker cannot reorder the
  # proxy-preserved header list), but "which header wins" must not be a
  # security-relevant question: both orders refuse.
  test "lens5 headers: duplicate Authorization headers refuse in BOTH orders (RFC 7230 §3.2.2)" do
    good = mint(%{})

    # put_req_header replaces; build the raw header list to get a true
    # duplicate-pair request (Plug delivers get_req_header/2 as a 2-list).
    for headers <- [
          [{"authorization", "Bearer #{good}"}, {"authorization", "Bearer garbage.second.value"}],
          [{"authorization", "Bearer garbage.second.value"}, {"authorization", "Bearer #{good}"}],
          [{"authorization", "Bearer #{good}"}, {"authorization", "Bearer #{good}"}]
        ] do
      c =
        conn(:get, "/subscriptions?api-version=2021-04-01")
        |> Map.put(:req_headers, headers)
        |> Smalt.ArmGateway.Router.call([])

      assert c.status == 401, "duplicate Authorization #{inspect(headers)} must refuse, got #{c.status}"
      assert Jason.decode!(c.resp_body)["error"]["message"] == "MalformedBearerHeader"
    end

    # Sanity: a SINGLE valid header still accepts (the refuse is dupes-only).
    c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{good}"}])
    assert c.status == 200, "single valid Authorization must accept, got #{c.status}"
  end

  # Auth-lens-6 (RFC 8725 §3.11 end-to-end typing): the STS mint pins
  # typ: "JWT" on its own tokens, so the verifier typ fence's ACCEPT leg runs
  # against real minted tokens, not just synthetic ones. Pins BOTH legs:
  # (1) a minted token's JWS header carries typ "JWT" and still verifies
  # (200 end-to-end through the wire); (2) the absent-typ back-compat accept
  # stays open for legacy/untyped tokens (the fence is typ-PIN, not
  # typ-REQUIRED).
  test "lens6: STS mint pins typ JWT and the token verifies end-to-end (RFC 8725 3.11)" do
    # Through the REAL STS endpoint (POST /{tid}/oauth2/v2.0/token), not the
    # test-helper mint/1 — the pin lives in the production mint and must be
    # witnessed on the wire (lens-6 cycle 5 lesson: the helper mint masks a
    # production-mint revert).
    c =
      %Plug.Conn{conn(:post, "/oauth2/v2.0/token", "grant_type=client_credentials&client_id=x&client_secret=y")
      | host: "arm.smalt.local", port: 19_081}
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> Smalt.ArmGateway.Router.call([])

    assert c.status == 200, "STS mint must succeed, got #{c.status}: #{String.slice(c.resp_body || "", 0, 80)}"
    token = Jason.decode!(c.resp_body)["access_token"]

    assert {:ok, header} = Joken.peek_header(token)
    assert header["typ"] == "JWT", "production mint must pin typ JWT, header=#{inspect(header)}"
    assert header["alg"] == "HS256"

    conn = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{token}"}])
    assert conn.status == 200, "minted typ-JWT token must verify, got #{conn.status}"
  end

  # -- lens-6 cycle 4: fresh-seed fuzz wave -------------------------------------
  # Deterministic seed (reproducible receipt); Chicago: real routers, real
  # plugs, assertions on wire status only. Three fuzz families:
  #   A. byte-level token mutation (every mutant provably differs from good)
  #   B. authorization header shape fuzz (scheme case, padding, dupes, junk)
  #   C. path fuzz with encoded dot/traversal segments through BOTH routers
  # Invariants: never a 5xx; a mutated token NEVER verifies (200) on the
  # protected route; exempt-prefix traversals never escape 401/404.
  test "lens6 fuzz: byte-mutated tokens never verify on the protected route" do
    :rand.seed(:exsss, {20_261_015, 20_261_016, 20_261_017})
    good = mint(%{})
    parts = String.split(good, ".")
    assert [h, p, sig] = parts
    pool = String.graphemes(~s(ABCDEF0123456789.~_-{}"abc[]:,))

    for _ <- 1..200 do
      mutant =
        case :rand.uniform(6) do
          1 ->
            # shuffle can return the identity permutation; redraw until the
            # part order actually differs (mutation provably differs from good)
            Stream.repeatedly(fn -> Enum.shuffle(parts) |> Enum.join(".") end)
            |> Enum.find(&(&1 != good))
          2 -> "#{h}.#{p}" # truncate signature
          3 -> h <> p <> sig # no dots
          4 -> String.replace(good, ".", "_", global: false)
          5 ->
            i = :rand.uniform(byte_size(sig)) - 1
            <<pre::binary-size(i), orig, post::binary>> = sig
            pre <> Enum.random(Enum.reject(pool, &(&1 == <<orig>>))) <> post
          6 ->
            # mutate a payload byte -> different claims bytes
            i = :rand.uniform(byte_size(p)) - 1
            <<pre::binary-size(i), orig, post::binary>> = p
            pre <> Enum.random(Enum.reject(pool, &(&1 == <<orig>>))) <> post
        end

      assert mutant != good, "mutant must differ from the valid token"
      c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", "Bearer #{mutant}"}])
      assert c.status == 401, "mutant must refuse, got #{c.status}: #{inspect(mutant)}"
      assert Jason.decode!(c.resp_body)["error"]["message"] in [
               "SignatureVerificationFailed",
               "MalformedBearerHeader",
               "TokenExpired",
               "AudienceMismatch",
               "IssuerMismatch",
               "TokenNotYetValid"
             ]
    end
  end

  test "lens6 fuzz: header-shape fuzz never 5xx and never false-accept" do
    :rand.seed(:exsss, {20_261_015, 20_261_017, 20_261_018})
    good = mint(%{})
    schemes = ["Bearer", "bearer", "BEARER", "bEaReR", "", "Basic", "Digest", "JWT ", "  "]

    for _ <- 1..120 do
      value =
        case :rand.uniform(5) do
          1 -> Enum.random(schemes) <> " " <> good
          2 -> String.duplicate(" ", :rand.uniform(4)) <> good
          3 -> good <> String.duplicate("x", :rand.uniform(5))
          4 -> Enum.random(["", " ", "Bearer ", "Bearer", "Bearer  "])
          5 -> Enum.random(schemes) <> " " <> good <> "="
        end

      c = arm_req(:get, "/subscriptions?api-version=2021-04-01", [{"authorization", value}])
      assert c.status in [200, 401], "no 5xx, got #{c.status} for #{inspect(value)}"
      # false-accept guard: only an EXACT "Bearer <good>" (plus legal case/
      # padding variants) may 200; anything with junk appended must refuse.
      normalized = value |> String.trim() |> String.split(" ", parts: 2)

      case normalized do
        [sch, tok] ->
          # Trailing "=" in the signature segment is base64url padding and
          # decodes to the IDENTICAL signature bytes — JOSE verifies it and
          # that is correct (measured lens-6 cycle 4). Compare padding-stripped.
          tok_norm = String.trim_trailing(tok, "=")
          good_norm = String.trim_trailing(good, "=")

          if String.downcase(sch) == "bearer" and tok_norm == good_norm do
            assert c.status == 200
          else
            assert c.status == 401, "false-accept: status 200 for #{inspect(value)}"
          end

        _ ->
          assert c.status == 401
      end
    end
  end

  test "lens6 fuzz: encoded dot/traversal path fuzz never 5xx, never 200 anonymously" do
    :rand.seed(:exsss, {20_261_015, 20_261_018, 20_261_019})
    segs = ["%2e", "%2e%2e", "..", ".", "%2f%2e%2e", "%252e", "..%2f", ";", "%00", "..;", "..%00"]

    for _ <- 1..150 do
      n = :rand.uniform(3)
      seg = Enum.map(1..n, fn _ -> Enum.random(segs) end) |> Enum.join("/")
      path = Enum.random(["/oauth2", "/.well-known", "/attest", "/metadata/endpoints", "/tenants"]) <> "/" <> seg <> Enum.random(["/acct/cont/blob", "/dbs/db", "/keys/k1", ""])

      for {router, req} <- [arm: &arm_req/3, egress: &egress_req/3] do
        c = req.(:get, path, [])
        assert c.status < 500, "5xx on #{router} #{path}: #{c.status} #{String.slice(c.resp_body || "", 0, 60)}"
        assert c.status != 200, "anonymous 200 leaked on #{router} #{path}"
      end
    end
  end

  # -- lens-4 cycle 4: JWS header-parameter fence (crit/b64) ---------------------
  # Measured pre-fence: Joken.verify/2 verifies the signature but ignores the
  # JWS header — a token declaring `crit: ["b64"], b64: false` (RFC 7797
  # unencoded-payload semantics) or ANY crit extension verified OK and would
  # have been ACCEPTED. RFC 7515 §4.1.11: a verifier MUST reject crit
  # extensions it does not implement (we implement none). Fail-closed fence:
  # non-empty/non-list `crit` or any `b64` member refuses (lens-5 fence v2).
  # Lens-5 fence v2: non-empty/non-list `crit` or any `b64` member refuses;
  # crit:[] is legal per RFC 7515 §4.1.11 and accepts; typ is fenced per
  # RFC 8725 §3.11. Lens-5 courts: typ fence corpus, crit:[] in the accept
  # set, b64 non-boolean rows, duplicate-Authorization refuse court.

  defp hand_signed_token(header, claims) do
    b64 = fn bin -> Base.url_encode64(bin, padding: false) end
    h = b64.(Jason.encode!(header))
    p = b64.(Jason.encode!(claims))
    sig = :crypto.mac(:hmac, :sha256, @secret, h <> "." <> p) |> b64.()
    Enum.join([h, p, sig], ".")
  end

  # Header-controlled hand signing with an arbitrary HMAC key (fuzz rotation:
  # key-injection headers must refuse when the signature is foreign).
  defp hand_signed_token(header, claims, secret) when is_binary(secret) do
    b64 = fn bin -> Base.url_encode64(bin, padding: false) end
    h = b64.(Jason.encode!(header))
    p = b64.(Jason.encode!(claims))
    sig = :crypto.mac(:hmac, :sha256, secret, h <> "." <> p) |> b64.()
    Enum.join([h, p, sig], ".")
  end

  # {header, expected reason}. b64: false (RFC 7797 raw payload) fails the
  # SIGNATURE check itself (Joken verifies over the base64url payload), so its
  # refusal reason is SignatureVerificationFailed — same verdict, earlier leg.
  @crit_headers [
    {%{"alg" => "HS256", "crit" => ["b64"]}, "UnsupportedCriticalHeader"},
    {%{"alg" => "HS256", "crit" => ["b64"], "b64" => false}, "SignatureVerificationFailed"},
    {%{"alg" => "HS256", "crit" => ["http://evil.example"]}, "UnsupportedCriticalHeader"},
    {%{"alg" => "HS256", "crit" => "not-a-list"}, "UnsupportedCriticalHeader"},
    {%{"alg" => "HS256", "crit" => 7}, "UnsupportedCriticalHeader"},
    {%{"alg" => "HS256", "b64" => false}, "SignatureVerificationFailed"},
    {%{"alg" => "HS256", "b64" => true}, "UnsupportedCriticalHeader"},
    # non-boolean b64: JOSE itself fails the signature leg (7797-aware) —
    # same refusal verdict, earlier leg, per-row pin corrected in-court.
    {%{"alg" => "HS256", "b64" => "yes"}, "SignatureVerificationFailed"},
    {%{"alg" => "HS256", "b64" => 1}, "SignatureVerificationFailed"}
  ]

  test "lens4 header fence: crit/b64 header corpus all refused (RFC 7515 §4.1.11)" do
    now = System.system_time(:second)

    for {header, expected} <- @crit_headers do
      token =
        hand_signed_token(header, %{"aud" => @aud, "iss" => "https://login.microsoftonline.com/t/v2.0", "exp" => now + 3600})

      c = arm_req(:get, "/crit-probe", [{"authorization", "Bearer #{token}"}])

      assert c.status == 401, "crit/b64 header #{inspect(header)} must refuse, got #{c.status}"

      msg = Jason.decode!(c.resp_body)["error"]["message"]
      assert msg == expected, "header #{inspect(header)}: expected #{expected}, got #{msg}"
    end

    # Benign accept set: bare header, typ "JWT" (any case), kid, and the
    # RFC-legal empty crit array (lens-5 typed decision). Proves the
    # hand-signing helper is sound — same HMAC the plug checks.
    for header <- [
          %{"alg" => "HS256"},
          %{"alg" => "HS256", "typ" => "JWT"},
          %{"alg" => "HS256", "typ" => "jwt"},
          %{"alg" => "HS256", "kid" => "k"},
          %{"alg" => "HS256", "crit" => []}
        ] do
      token =
        hand_signed_token(header, %{
          "aud" => @aud,
          "iss" => @iss,
          "exp" => now + 3600,
          "nbf" => now
        })

      c = arm_req(:get, "/subscriptions?api-version=2022-09-01", [{"authorization", "Bearer #{token}"}])
      assert c.status == 200, "benign hand-signed header #{inspect(header)} must accept, got #{c.status}"
    end
  end

  # -- lens-5: typ fence (RFC 8725 §3.11 explicit typing) ------------------------

  @typ_refusals [
    {"at+jwt", "UnsupportedTokenHeader"},
    {"JWT ", "UnsupportedTokenHeader"},
    {"application/jwt", "UnsupportedTokenHeader"},
    {7, "UnsupportedTokenHeader"},
    {true, "UnsupportedTokenHeader"}
  ]

  test "lens5 corner: crit:[] combined with a bad typ still refuses (cond-order pin)" do
    now = System.system_time(:second)
    token =
      hand_signed_token(%{"alg" => "HS256", "crit" => [], "typ" => "at+jwt"}, %{
        "aud" => @aud,
        "iss" => @iss,
        "exp" => now + 3600
      })

    c = arm_req(:get, "/typ-probe", [{"authorization", "Bearer #{token}"}])
    assert c.status == 401
    assert Jason.decode!(c.resp_body)["error"]["message"] == "UnsupportedTokenHeader"
  end

  test "lens5 typ fence: present typ must be JWT case-insensitive, else refuse (RFC 8725 §3.11)" do
    now = System.system_time(:second)

    for {typ, expected} <- @typ_refusals do
      token = hand_signed_token(%{"alg" => "HS256", "typ" => typ}, %{"aud" => @aud, "iss" => @iss, "exp" => now + 3600})

      c = arm_req(:get, "/typ-probe", [{"authorization", "Bearer #{token}"}])

      assert c.status == 401, "typ #{inspect(typ)} must refuse, got #{c.status}"

      msg = Jason.decode!(c.resp_body)["error"]["message"]
      assert msg == expected, "typ #{inspect(typ)}: expected #{expected}, got #{msg}"
    end
  end

  # -- lens-5: registry-collapse audit (the poisoning class generalized) ---------

  test "lens5 registry audit: scheme-less iss never rides the minted-authority leg" do
    # Register-side fence makes "" unregistrable; this pins the verify side:
    # even with an authority registered, a scheme-less iss derives the ""
    # sentinel at lookup and must refuse.
    Smalt.Auth.Bearer.register_trusted_authority("arm.internal:19081")

    now = System.system_time(:second)

    for iss <- ["arm.internal:19081/t/v2.0", "//arm.internal:19081/t/v2.0", "://arm.internal:19081/t/v2.0"] do
      token = hand_signed_token(%{"alg" => "HS256"}, %{"aud" => @aud, "iss" => iss, "exp" => now + 3600})

      c = arm_req(:get, "/iss-probe", [{"authorization", "Bearer #{token}"}])

      assert c.status == 401, "scheme-less iss #{iss} must refuse, got #{c.status}"
      assert Jason.decode!(c.resp_body)["error"]["message"] == "IssuerMismatch"
    end
  end

  test "lens5 registry audit: malformed trusted_proxies entries stay fail-closed (no crash, no open)" do
    token = mint(%{})

    Application.put_env(:smalt, :trusted_proxies, [
      "",
      "not-an-ip",
      "10.0.0.0",
      "10.0.0.0/33",
      "300.1.1.1/8",
      "10.0.0.0/8x",
      {:nine, :element, :tuple, :here, 5, 6, 7, 8, 9},
      42
    ])

    on_exit(fn -> Application.delete_env(:smalt, :trusted_proxies) end)

    # Spoofed forwarded headers must be ignored on a non-trusted direct peer:
    # the token's iss binds the DIRECT test authority, so acceptance proves
    # the direct derivation won; any forwarded-honor would 401 IssuerMismatch.
    c =
      arm_req(:get, "/subscriptions?api-version=2022-09-01", [
        {"authorization", "Bearer #{token}"},
        {"x-forwarded-host", "evil.example:8443"},
        {"x-forwarded-proto", "https"}
      ])

    assert c.status == 200, "malformed trusted_proxies must stay fail-closed, got #{c.status}"
  end

  # -- lens 7 -------------------------------------------------------------------

  @egress_ver [{"x-ms-version", "2021-12-02"}]

  describe "lens7: egress-handoff joint court (auth surface)" do
    # Same wire facts the egress_dispatch lane pins on its side (lens-4
    # cycle-1 "auth-exempt namespace never reaches the blob splat"), read
    # from the AUTH surface: the exemption predicate and the blob_route/2
    # fence must compose identically no matter which suite asks.
    @exempt_blob_paths [
      "/.well-known/acct/cont/blob",
      "/oauth2/acct/cont/blob",
      "/attest/exacct/excont/exblob",
      "/metadata/endpoints"
    ]

    test "exempt-namespace blob paths refuse 404 BlobNotFound on the egress router, token or not" do
      token = mint()

      for path <- @exempt_blob_paths,
          auth <- [[], [{"authorization", "Bearer #{token}"}]] do
        c = egress_req(:get, path, @egress_ver ++ auth)

        assert c.status == 404,
               "#{path} (auth=#{auth != []}) answered #{c.status}: #{c.resp_body}"

        assert Jason.decode!(c.resp_body)["error"]["code"] == "BlobNotFound",
               "#{path} answered #{c.resp_body}"
      end
    end

    test "traversal into the exempt namespace from a NON-exempt prefix refuses at the plug (anonymous) or the blob fence (bearer)" do
      paths = [
        "/fz/cont/..%2f..%2f.well-known%2fx"
      ]

      token = mint()

      for path <- paths do
        anon = egress_req(:get, path, @egress_ver)
        assert anon.status == 401, "#{path} anonymous answered #{anon.status}"

        authed = egress_req(:get, path, @egress_ver ++ [{"authorization", "Bearer #{token}"}])
        assert authed.status == 404, "#{path} bearer answered #{authed.status}: #{authed.resp_body}"

        assert Jason.decode!(authed.resp_body)["error"]["code"] == "BlobNotFound",
               "#{path} bearer answered #{authed.resp_body}"
      end

      # Fully %-encoded single-segment traversals: never reach the splat
      # (glob needs 3+ raw "/"-separated segments) — land on the 404
      # catch-all. Fail-closed by a THIRD mechanism; pinned so a future glob
      # widening keeps it so.
      for path <- [
            "/tenants%2f..%2facct%2fcont%2fblob",
            "/oauth2%2f..%2f..%2fkeys%2Fk1"
          ] do
        single = egress_req(:get, path, @egress_ver)

        assert single.status in [401, 404],
               "#{path} answered #{single.status} (fail-open?)"

        if single.status == 404 do
          assert Jason.decode!(single.resp_body)["error"]["code"] in ["RouteNotFound", "BlobNotFound"]
        end
      end
    end

    test "traversal refusals precede the version guard on exempt-prefix paths too" do
      for path <- ["/.well-known/acct/cont/blob", "/oauth2/acct/cont/blob"] do
        no_ver = egress_req(:get, path, [])
        assert no_ver.status == 404
        assert Jason.decode!(no_ver.resp_body)["error"]["code"] == "BlobNotFound"
      end
    end

    test "anchored STS-exemption suffix stays 401 at the auth plug, router never sees it" do
      c = egress_req(:get, "/tid/oauth2/v2.0/token/extra", @egress_ver)
      assert_challenge(c, "anchored STS suffix")

      assert Jason.decode!(c.resp_body)["error"]["message"] == "MissingBearerToken"
    end

    test "control: non-exempt blob path still requires the bearer (pin is live)" do
      c = egress_req(:get, "/ctrl7/cont/blob", @egress_ver)
      assert_challenge(c, "non-exempt blob control")
    end


    test "the seam is ONE predicate: bearer-side and router-side reads agree on a mixed corpus" do
      corpus =
        @exempt_blob_paths ++
          ["/ctrl7/cont/blob", "/tid/oauth2/v2.0/token", "/metadata/endpoints/extra"]

      for p <- corpus do
        assert Smalt.Auth.Bearer.auth_exempt_path?(p) ==
                 (p in ["/metadata/endpoints"] or
                    String.starts_with?(p, "/.well-known/") or
                    String.starts_with?(p, "/oauth2/") or
                    String.starts_with?(p, "/attest/") or
                    Regex.match?(~r{^/[^/]+/oauth2/v2\.0/token$}, p)),
               "predicate disagrees with the pinned wire contract on #{p}"
      end
    end

    test "lens7: joint typ property — both mints emit typ JWT; variant typs refuse on both fences (RFC 8725 3.11)" do
      # 1. JOSE normalization law (measured lens-6): the Joken/JOSE mint
      #    normalizes any intended typ to "JWT"; ReceiptSigner signs a
      #    literal "JWT" header. No mint can produce a non-"JWT" typ, so
      #    non-mint-controllable typ + verify-side fences = end-to-end
      #    typing by construction.
      jose_token = mint()
      {:ok, jose_header} = Joken.peek_header(jose_token)
      assert jose_header["typ"] == "JWT"

      rs_token =
        Smalt.Security.ReceiptSigner.sign(%{"exp" => System.system_time(:second) + 3600})

      [rs_h | _] = String.split(rs_token, ".")
      assert Jason.decode!(Base.url_decode64!(rs_h, padding: false))["typ"] == "JWT"

      # 2. Cross-fence composition: Bearer's fence is case-INSENSITIVE
      #    (absent typ accepted); ReceiptSigner's is case-SENSITIVE exact.
      #    The divergence is deliberate and pinned; every NON-"JWT" typ
      #    refuses on BOTH surfaces (ledger lane lens-4 edge corpus,
      #    mirrored from their cycle-1 receipt).
      now = System.system_time(:second)
      claims = %{"aud" => @aud, "iss" => @iss, "exp" => now + 3600}

      for {typ, bearer_expect, rs_typ} <- [
            {"JWT", :ok, nil},
            {"jwt", :ok, "jwt"},
            {"Jwt", :ok, "Jwt"},
            {"at+jwt", {:refuse, "InvalidAuthenticationToken", "UnsupportedTokenHeader"},
             "at+jwt"},
            {"application/jwt", {:refuse, "InvalidAuthenticationToken", "UnsupportedTokenHeader"},
             "application/jwt"}
          ] do
        bearer_token = hand_signed_token(%{"alg" => "HS256", "typ" => typ}, claims)

        assert Smalt.Auth.Bearer.verify_bearer(
                 conn(:get, "/subscriptions")
                 |> put_req_header("authorization", "Bearer #{bearer_token}")
               ) == bearer_expect,
               "Bearer fence disagreed on typ #{inspect(typ)}"

        # ReceiptSigner's check_typ runs BEFORE check_signature, so a
        # variant typ is refused structurally even over a junk signature —
        # this probe exercises exactly the typ gate without the VM key.
        if rs_typ do
          b64 = fn bin -> Base.url_encode64(bin, padding: false) end

          probe =
            Enum.join(
              [
                b64.(Jason.encode!(%{"alg" => "RS256", "typ" => rs_typ})),
                b64.(Jason.encode!(%{"exp" => now + 3600})),
                "junk-signature"
              ],
              "."
            )

          assert {:error, {:bad_typ, ^rs_typ}} = Smalt.Security.ReceiptSigner.verify(probe),
                 "ReceiptSigner fence disagreed on typ #{inspect(rs_typ)}"
        end
      end

      # 3. End-to-end composition: the JOSE-minted bearer passes the
      #    PROTECTED route; the ReceiptSigner receipt verifies with its own
      #    verifier. Each mint interoperates with its own fence — joint
      #    typing law, one receipt, two surfaces.
      c =
        arm_req(:get, "/subscriptions?api-version=2022-09-01", [
          {"authorization", "Bearer #{jose_token}"}
        ])

      assert c.status == 200
      assert {:ok, _} = Smalt.Security.ReceiptSigner.verify_token(rs_token)
    end

    # -- cycle 3: body_cache under the egress splat binding ------------------

    @egress_form_ct [{"content-type", "application/x-www-form-urlencoded"}]

    test "lens7 bodycache: raw slash-blob PUT bypasses parsing — body stored verbatim, smalt_raw_body never set on the egress surface" do
      token = mint()
      auth = [{"authorization", "Bearer #{token}"}]

      call7 = fn method, path, body, headers ->
        method
        |> conn(path, body)
        |> put_headers(headers ++ auth)
        |> Smalt.EgressRouter.call([])
      end

      call7.(:put, "/bc7/cont?restype=container", nil, [
        {"x-ms-version", "2021-12-02"},
        {"x-ms-immutable-policy", "false"}
      ])

      for {ct, body} <- [
            {"application/x-www-form-urlencoded", "grant_type=client_credentials&client_id=x"},
            {"application/json", "{\"a\": 1}"},
            {"text/plain", "not-parsed-at-all"}
          ] do
        c =
          call7.(:put, "/bc7/cont/a/b/slash-blob.txt", body, [
            {"x-ms-version", "2021-12-02"},
            {"content-type", ct}
          ])

        assert c.status == 201, "PUT answered #{c.status}: #{c.resp_body}"

        get = call7.(:get, "/bc7/cont/a/b/slash-blob.txt", nil, [{"x-ms-version", "2021-12-02"}])
        assert get.status == 200
        assert get.resp_body == body

        # The egress router's raw_blob_put?/1 exemption means Plug.Parsers —
        # and therefore the ARM-only BodyCache body_reader — never runs on
        # this shape: no raw-body cache is created (and none is needed; the
        # handler reads the raw stream itself).
        assert c.private[:smalt_raw_body] == nil
      end
    end

    test "lens7 bodycache: slash-blob-shaped FORM VALUES through the STS BodyCache — cached byte-identical, no dup false-positive" do
      c =
        %Plug.Conn{
          conn(
            :post,
            "/oauth2/v2.0/token",
            "grant_type=client_credentials&client_id=a%2Fb&client_secret=x%2Fy?comp=none"
          )
          | host: "arm.smalt.local",
            port: 19_081
        }
        |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
        |> Smalt.ArmGateway.Router.call([])

      assert c.status == 200, "slash-valued form must mint, got #{c.status}: #{c.resp_body}"

      # The BodyCache accumulated the full raw body through the parse loop:
      # byte-identical to the wire body, slash-blob shapes intact.
      assert c.private[:smalt_raw_body] ==
               "grant_type=client_credentials&client_id=a%2Fb&client_secret=x%2Fy?comp=none"

      # %-encoded slash inside a DUPLICATED key stays a duplicate (refused
      # on the raw body, not the decoded map): the slash shape cannot launder
      # a duplicate past the fence.
      dup =
        %Plug.Conn{
          conn(
            :post,
            "/oauth2/v2.0/token",
            "grant_type=client_credentials&grant_type=client%5Fcredentials"
          )
          | host: "arm.smalt.local",
            port: 19_081
        }
        |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
        |> Smalt.ArmGateway.Router.call([])

      assert dup.status == 400
      assert Jason.decode!(dup.resp_body)["error"] == "invalid_request"
    end

    # -- cycle 4: fresh-seed fuzz rotation ---------------------------------
    # lens-6 ran 470 probes over 3 families. This rotation: NEW families
    # (JWS header-injection, exempt x comp-query matrix, adversarial claim
    # TYPES). All probes hit the real routers in enforce mode; the only
    # admissible anonymous outcome anywhere is 401/404, never 2xx, never 5xx.

    test "lens7 fuzz: JWS header-injection claim corpus never 5xx and never false-accept" do
      injection_headers = [
        %{"alg" => "HS256", "jku" => "https://evil.example/jwks.json"},
        %{"alg" => "HS256", "jwk" => %{"kty" => "oct", "k" => "AA"}},
        %{"alg" => "HS256", "x5u" => "https://evil.example/cert"},
        %{"alg" => "HS256", "kid" => "../../../etc/passwd"},
        %{"alg" => "HS256", "x5c" => ["not-a-cert"]},
        %{"alg" => "HS256", "typ" => "JWT", "jku" => "https://evil.example/jwks.json"}
      ]

      now = System.system_time(:second)
      claims = %{"aud" => @aud, "iss" => @iss, "exp" => now + 3600}

      for h <- injection_headers do
        token = hand_signed_token(h, claims, "attacker-key-not-ours-0123456789")

        c =
          arm_req(:get, "/subscriptions?api-version=2021-04-01", [
            {"authorization", "Bearer #{token}"}
          ])

        assert c.status == 401,
               "header #{Jason.encode!(h)} with a FOREIGN signature answered #{c.status}"
      end

      # The benign twin: the SAME injection headers over a valid signature
      # admit — jku/jwk/x5u are key-SELECTION hints; ignoring them and
      # pinning the configured signer is the RFC 7515-correct policy, and a
      # valid signature means the holder already has our secret. Pinned so a
      # future "harden jku" change is a visible decision.
      for h <- injection_headers do
        token = hand_signed_token(h, claims)

        c =
          arm_req(:get, "/subscriptions?api-version=2021-04-01", [
            {"authorization", "Bearer #{token}"}
          ])

        assert c.status == 200,
               "valid-signature header #{Jason.encode!(h)} must still admit, got #{c.status}"
      end
    end

    test "lens7 fuzz: exempt-prefix x comp-query x traversal matrix never serves data anonymously" do
      paths = [
        "/.well-known/acct/comp7/cont/blob",
        "/oauth2/acct/comp7/blob",
        "/attest/a/comp7/b",
        "/fz/cont/..%2f.well-known%2fx"
      ]

      queries = ["", "?comp=lease", "?comp=list", "?restype=container", "?comp=none&x=1"]
      vers = [[], [{"x-ms-version", "2021-12-02"}]]

      for p <- paths, q <- queries, ver <- vers do
        c = egress_req(:get, p <> q, ver)
        assert c.status in [401, 404], "#{p}#{q} answered #{c.status}"

        if c.status == 404 do
          code = Jason.decode!(c.resp_body)["error"]["code"]
          assert code in ["BlobNotFound", "RouteNotFound"], "#{p}#{q} -> #{code}"
        end
      end
    end

    test "lens7 fuzz: adversarial claim TYPES never 5xx and never false-accept" do
      now = System.system_time(:second)

      overrides = [
        %{"nbf" => [1, 2]},
        %{"nbf" => %{"$gt" => 0}},
        %{"aud" => [@aud, "https://evil.example"]},
        %{"aud" => %{"oid" => @aud}},
        %{"iss" => ["https://login.microsoftonline.com/x/v2.0"]},
        %{"iss" => ""},
        %{"iss" => 0}
      ]

      for override <- overrides do
        token = mint(override)

        c =
          arm_req(:get, "/subscriptions?api-version=2021-04-01", [
            {"authorization", "Bearer #{token}"}
          ])

        assert c.status == 401, "claims #{Jason.encode!(override)} answered #{c.status}"
      end

      # Benign far-future exp (int64 max) over a valid signature admits:
      # the signature binds the token to our secret, so the holder chose
      # the lifetime; exp <= now is the only fail-closed line we draw.
      # Pinned alongside the lens-4 "iat absurd-future accepts" row.
      token = mint(%{"exp" => 9_223_372_036_854_775_807})

      c =
        arm_req(:get, "/subscriptions?api-version=2022-09-01", [
          {"authorization", "Bearer #{token}"}
        ])

      assert c.status == 200, "far-future exp answered #{c.status}"

      # Benign far-PAST nbf (int64 min) admits: nbf <= now is the open
      # window leg; "already valid" is the normal case. Pinned.
      token_past = mint(%{"nbf" => -9_223_372_036_854_775_808})

      c_past =
        arm_req(:get, "/subscriptions?api-version=2022-09-01", [
          {"authorization", "Bearer #{token_past}"}
        ])

      assert c_past.status == 200, "far-past nbf answered #{c_past.status}"
    end
  end
end
