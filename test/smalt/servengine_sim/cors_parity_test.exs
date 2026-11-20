defmodule Smalt.ServengineSim.CorsParityTest do
  use ExUnit.Case, async: false

  alias Smalt.ServengineSim.CorsParity
  alias Smalt.ServengineSim.CorsParity.Endpoint

  @servengine_headers [
    "X-Location",
    "x-avion-action",
    "acting-entity-id",
    "X-Tenant-Id",
    "Authorization",
    "impersonation-session-id"
  ]

  setup do
    prev_cors_origins = System.get_env("CORS_ORIGINS")

    on_exit(fn ->
      case prev_cors_origins do
        nil -> System.delete_env("CORS_ORIGINS")
        val -> System.put_env("CORS_ORIGINS", val)
      end
    end)

    System.delete_env("CORS_ORIGINS")
    :ok
  end

  defp put_cors_origins_env(val) do
    System.put_env("CORS_ORIGINS", val)
  end

  defp preflight_conn(path, origin, req_method, req_headers) do
    headers =
      [{"origin", origin}, {"access-control-request-method", req_method}] ++
        case req_headers do
          nil -> []
          list when is_list(list) -> [{"access-control-request-headers", Enum.join(list, ",")}]
          bin when is_binary(bin) -> [{"access-control-request-headers", bin}]
        end

    Plug.Test.conn(:options, path)
    |> Map.put(:req_headers, headers)
  end

  describe "servengine-frontend header inventory" do
    test "exposes all six required servengine-frontend headers" do
      assert CorsParity.servengine_frontend_headers() == @servengine_headers
    end

    test "default_allowed_headers/0 includes every servengine-frontend header plus standard headers" do
      downcased = Enum.map(CorsParity.default_allowed_headers(), &String.downcase/1)

      for header <- @servengine_headers do
        assert String.downcase(header) in downcased
      end

      assert "content-type" in downcased
      assert "accept" in downcased
      assert "x-requested-with" in downcased
    end
  end

  describe "CORS_ORIGINS parsing and origin matching" do
    test "defaults to servengine ALB and PHX_HOST origins when CORS_ORIGINS is unset" do
      assert CorsParity.allowed_origins() == [
               "https://servengine.fnox.io",
               "https://servegine.fnox.io",
               "https://xaas.fnox.io"
             ]

      assert CorsParity.origin_allowed?("https://servengine.fnox.io")
      assert CorsParity.origin_allowed?("https://servegine.fnox.io")
      assert CorsParity.origin_allowed?("https://xaas.fnox.io")
      refute CorsParity.origin_allowed?("https://evil.example")
    end

    test "parses comma-separated CORS_ORIGINS env var with whitespace, trailing slashes, and ports" do
      put_cors_origins_env(
        "  HTTPS://APP.FNOX.IO/ , http://localhost:5173/ , https://admin.fnox.io  "
      )

      assert CorsParity.allowed_origins() == [
               "https://app.fnox.io",
               "http://localhost:5173",
               "https://admin.fnox.io"
             ]

      assert CorsParity.origin_allowed?("https://app.fnox.io")
      assert CorsParity.origin_allowed?("https://app.fnox.io:443")
      assert CorsParity.origin_allowed?("http://localhost:5173")
      refute CorsParity.origin_allowed?("http://localhost:5174")
      refute CorsParity.origin_allowed?("https://servengine.fnox.io")
    end

    test "empty CORS_ORIGINS fails closed and rejects all origins" do
      put_cors_origins_env("")
      assert CorsParity.allowed_origins() == []
      refute CorsParity.origin_allowed?("https://servengine.fnox.io")

      conn =
        preflight_conn("/api/rpc", "https://servengine.fnox.io", "POST", @servengine_headers)
        |> Endpoint.call([])

      assert conn.status == 403
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "rejects malformed, hostless, and null origins even when wildcard is absent" do
      refute CorsParity.origin_allowed?("null")
      refute CorsParity.origin_allowed?("")
      refute CorsParity.origin_allowed?("javascript:alert(1)")
      refute CorsParity.origin_allowed?("ftp://servengine.fnox.io")
    end

    test "supports wildcard subdomain entries like https://*.fnox.io" do
      put_cors_origins_env("https://*.fnox.io")

      assert CorsParity.origin_allowed?("https://servengine.fnox.io")
      assert CorsParity.origin_allowed?("https://staging.servengine.fnox.io")
      refute CorsParity.origin_allowed?("https://fnox.io")
      refute CorsParity.origin_allowed?("https://evil-fnox.io")
      refute CorsParity.origin_allowed?("http://servengine.fnox.io")
    end
  end

  describe "OPTIONS preflight simulation for servengine-frontend headers" do
    test "combined preflight allows all six servengine-frontend headers across CORS_ORIGINS" do
      put_cors_origins_env("https://servengine.fnox.io,https://servegine.fnox.io")

      for origin <- ["https://servengine.fnox.io", "https://servegine.fnox.io"] do
        # Browsers lowercase Access-Control-Request-Headers on the wire.
        wire_req_headers = Enum.map(@servengine_headers, &String.downcase/1)

        assert {:ok, report} =
                 CorsParity.verify_preflight(Endpoint,
                   origin: origin,
                   path: "/api/rpc",
                   request_method: "POST",
                   request_headers: wire_req_headers,
                   expected_headers: @servengine_headers
                 )

        assert report.http_status == 204
        assert report.halted == true
        assert report.allow_origin == origin
        assert report.missing_headers == []
        assert "POST" in report.allow_methods
        assert Plug.Conn.get_resp_header(report.conn, "vary") == ["origin"]
        assert Plug.Conn.get_resp_header(report.conn, "access-control-max-age") == ["86400"]
      end
    end

    for header <- @servengine_headers do
      test "individual preflight allows servengine-frontend header #{header}" do
        assert {:ok, report} =
                 CorsParity.verify_preflight(Endpoint,
                   origin: "https://servengine.fnox.io",
                   path: "/api/rpc",
                   request_method: "POST",
                   request_headers: [String.downcase(unquote(header))],
                   expected_headers: [unquote(header)]
                 )

        assert report.http_status == 204
        assert report.missing_headers == []
      end
    end

    test "verify_matrix/2 passes for all admitted CORS_ORIGINS and rejects untrusted origin" do
      put_cors_origins_env(
        "https://servengine.fnox.io, https://servegine.fnox.io, https://xaas.fnox.io"
      )

      assert {:ok, summary} = CorsParity.verify_matrix(Endpoint)

      assert summary.origins_tested == [
               "https://servengine.fnox.io",
               "https://servegine.fnox.io",
               "https://xaas.fnox.io"
             ]

      assert summary.untrusted_rejected? == true
      assert summary.failures == []
      # 3 origins * (1 combined + 6 per-header) = 21 preflight probes
      assert length(summary.results) == 21
    end

    test "wildcard CORS_ORIGINS emits * without credentials, and echoes origin with credentials" do
      assert {:ok, no_creds} =
               CorsParity.verify_preflight(
                 {CorsParity, [cors_origins: ["*"], allow_credentials: false]},
                 origin: "https://servengine.fnox.io"
               )

      assert no_creds.allow_origin == "*"
      assert no_creds.allow_credentials == nil

      assert {:ok, with_creds} =
               CorsParity.verify_preflight(
                 {CorsParity, [cors_origins: ["*"], allow_credentials: true]},
                 origin: "https://servengine.fnox.io"
               )

      assert with_creds.allow_origin == "https://servengine.fnox.io"
      assert with_creds.allow_credentials == "true"
      assert Plug.Conn.get_resp_header(with_creds.conn, "vary") == ["origin"]
    end
  end

  describe "anti-vacuity refusal checks" do
    test "refuses and identifies exact missing servengine-frontend headers" do
      # Default CORSPlug header list omits X-Location, x-avion-action,
      # acting-entity-id, X-Tenant-Id, and impersonation-session-id.
      incomplete_plug =
        {CorsParity,
         [
           cors_origins: ["https://servengine.fnox.io"],
           headers: ["Authorization", "Content-Type", "Accept"]
         ]}

      assert {:refused, report} =
               CorsParity.verify_preflight(incomplete_plug,
                 origin: "https://servengine.fnox.io"
               )

      assert report.missing_headers == [
               "X-Location",
               "x-avion-action",
               "acting-entity-id",
               "X-Tenant-Id",
               "impersonation-session-id"
             ]

      assert {:missing_headers, report.missing_headers} in report.reasons
    end

    test "refuses disallowed origin preflight with 403 and zero allow headers" do
      assert {:refused, report} =
               CorsParity.verify_preflight(Endpoint,
                 origin: "https://evil.example",
                 path: "/api/rpc"
               )

      assert report.http_status == 403
      assert report.allow_origin == nil
      assert :missing_allow_origin in report.reasons
      assert {:bad_status, 403} in report.reasons
    end

    test "refuses invalid wildcard allow-origin paired with allow-credentials: true" do
      broken_plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
        |> Plug.Conn.put_resp_header("access-control-allow-credentials", "true")
        |> Plug.Conn.put_resp_header("access-control-allow-methods", "POST,OPTIONS")
        |> Plug.Conn.put_resp_header(
          "access-control-allow-headers",
          Enum.join(@servengine_headers, ",")
        )
        |> Plug.Conn.send_resp(204, "")
        |> Plug.Conn.halt()
      end

      assert {:refused, report} =
               CorsParity.verify_preflight(broken_plug, origin: "https://servengine.fnox.io")

      assert :wildcard_origin_with_credentials in report.reasons
    end

    test "refuses Authorization under wildcard Access-Control-Allow-Headers when credentials enabled" do
      wildcard_headers_with_creds = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("access-control-allow-origin", "https://servengine.fnox.io")
        |> Plug.Conn.put_resp_header("access-control-allow-credentials", "true")
        |> Plug.Conn.put_resp_header("access-control-allow-methods", "POST,OPTIONS")
        |> Plug.Conn.put_resp_header("access-control-allow-headers", "*")
        |> Plug.Conn.send_resp(204, "")
        |> Plug.Conn.halt()
      end

      assert {:refused, report} =
               CorsParity.verify_preflight(wildcard_headers_with_creds,
                 origin: "https://servengine.fnox.io"
               )

      assert report.missing_headers == ["Authorization"]
    end

    test "verify_matrix/2 refuses a permissive target that leaks ACAO to untrusted origins" do
      permissive_plug = {CorsParity, [cors_origins: ["*"]]}

      assert {:refused, summary} = CorsParity.verify_matrix(permissive_plug)
      assert summary.untrusted_rejected? == false
    end
  end

  describe "actual requests and Smalt.EgressRouter parity" do
    test "actual POST /api/rpc with allowed origin receives ACAO and all six headers" do
      req_headers = [
        {"origin", "https://servengine.fnox.io"},
        {"content-type", "application/json"},
        {"x-location", "loc-42"},
        {"x-avion-action", "dispatch.create"},
        {"acting-entity-id", "ent-99"},
        {"x-tenant-id", "tenant-7"},
        {"authorization", "Bearer tok-123"},
        {"impersonation-session-id", "imp-55"}
      ]

      conn =
        Plug.Test.conn(:post, "/api/rpc", ~s({"op":"ping"}))
        |> Map.put(:req_headers, req_headers)
        |> Endpoint.call([])

      assert conn.status == 200

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == [
               "https://servengine.fnox.io"
             ]

      assert Plug.Conn.get_resp_header(conn, "vary") == ["origin"]

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"

      assert body["headers"] == %{
               "X-Location" => "loc-42",
               "x-avion-action" => "dispatch.create",
               "acting-entity-id" => "ent-99",
               "X-Tenant-Id" => "tenant-7",
               "Authorization" => "Bearer tok-123",
               "impersonation-session-id" => "imp-55"
             }
    end

    test "requests without Origin pass through untouched without CORS headers" do
      conn =
        Plug.Test.conn(:get, "/healthz")
        |> Endpoint.call([])

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == []
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-headers") == []
    end

    test "disallowed Origin on GET /healthz answers 200 with NO ACAO header" do
      conn =
        Plug.Test.conn(:get, "/healthz")
        |> Map.put(:req_headers, [{"origin", "https://evil.example"}])
        |> Endpoint.call([])

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "Smalt.EgressRouter preflight admits all six servengine-frontend headers under default egress CORS" do
      assert {:ok, report} =
               CorsParity.verify_preflight(Smalt.EgressRouter,
                 path: "/keys/test-key",
                 origin: "https://servengine.fnox.io",
                 request_method: "POST",
                 require_allow_methods: false
               )

      assert report.http_status == 204
      assert report.missing_headers == []
    end
  end
end
