defmodule Smalt.ServengineSim.EdgeHeadersSimTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Smalt.ServengineSim.EdgeHeadersSim

  defmodule DownstreamApp do
    use Plug.Router

    plug(EdgeHeadersSim)
    plug(:match)
    plug(:dispatch)

    get "/duckdb/query" do
      send_resp(conn, 200, "ok")
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  describe "HTTP -> HTTPS 301 redirect" do
    test "redirects plaintext HTTP requests with 301 and Location to https://" do
      conn =
        conn(:get, "http://agents.fnox.io/duckdb/boot?engine=coi&aoq=1")
        |> EdgeHeadersSim.call(EdgeHeadersSim.init([]))

      assert conn.halted
      assert conn.status == 301
      assert conn.resp_body == ""

      assert get_resp_header(conn, "location") == [
               "https://agents.fnox.io/duckdb/boot?engine=coi&aoq=1"
             ]

      assert get_resp_header(conn, "cross-origin-opener-policy") == []
      assert get_resp_header(conn, "cross-origin-embedder-policy") == []
      assert get_resp_header(conn, "alt-svc") == []
    end

    test "strips non-443 HTTP port and honors custom https_port and forwarded host" do
      conn =
        conn(:get, "http://internal:8080/aoq/stream")
        |> put_req_header("x-forwarded-host", "edge.fnox.io:8080, proxy.internal")
        |> EdgeHeadersSim.call(EdgeHeadersSim.init(https_port: 8443))

      assert conn.halted
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["https://edge.fnox.io:8443/aoq/stream"]
    end

    test "redirects when x-forwarded-proto is http even on https conn" do
      conn =
        conn(:get, "https://agents.fnox.io/app")
        |> put_req_header("x-forwarded-proto", "http")
        |> EdgeHeadersSim.call([])

      assert conn.halted
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["https://agents.fnox.io/app"]
    end

    test "preserves bracketed IPv6 host literal when stripping HTTP port" do
      conn_from_uri =
        conn(:get, "http://[::1]:8080/health")
        |> EdgeHeadersSim.call([])

      assert conn_from_uri.status == 301
      assert get_resp_header(conn_from_uri, "location") == ["https://[::1]/health"]

      conn_from_xfh =
        conn(:get, "/health")
        |> put_req_header("x-forwarded-host", "[::1]:8080")
        |> EdgeHeadersSim.call([])

      assert conn_from_xfh.status == 301
      assert get_resp_header(conn_from_xfh, "location") == ["https://[::1]/health"]
    end
  end

  describe "GCP ALB edge headers on HTTPS (DuckDB-Wasm + AoQ)" do
    test "stamps COOP same-origin, COEP credentialless, and alt-svc h3=\":443\"" do
      conn =
        conn(:get, "https://agents.fnox.io/duckdb/coi")
        |> EdgeHeadersSim.call(EdgeHeadersSim.init([]))

      refute conn.halted
      assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
      assert get_resp_header(conn, "cross-origin-embedder-policy") == ["credentialless"]
      assert get_resp_header(conn, "alt-svc") == [~s(h3=":443")]
      assert EdgeHeadersSim.verify_edge_headers(conn) == :ok
    end

    test "accepts x-forwarded-proto: https behind TLS-terminating proxy" do
      conn =
        conn(:get, "http://agents.fnox.io/duckdb/coi")
        |> put_req_header("x-forwarded-proto", "https")
        |> EdgeHeadersSim.call([])

      refute conn.halted
      assert EdgeHeadersSim.effective_scheme(conn) == :https
      assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
      assert get_resp_header(conn, "cross-origin-embedder-policy") == ["credentialless"]
      assert get_resp_header(conn, "alt-svc") == [~s(h3=":443")]
    end

    test "supports redirect_http?: false for local non-TLS test harnesses" do
      conn =
        conn(:get, "http://127.0.0.1/duckdb")
        |> EdgeHeadersSim.call(EdgeHeadersSim.init(redirect_http?: false))

      refute conn.halted
      assert EdgeHeadersSim.verify_edge_headers(conn) == :ok
    end

    test "works as a Plug.Router middleware plug" do
      http_conn = DownstreamApp.call(conn(:get, "http://agents.fnox.io/duckdb/query"), [])
      assert http_conn.status == 301
      assert http_conn.halted
      assert get_resp_header(http_conn, "location") == ["https://agents.fnox.io/duckdb/query"]

      https_conn = DownstreamApp.call(conn(:get, "https://agents.fnox.io/duckdb/query"), [])
      assert https_conn.status == 200
      assert https_conn.resp_body == "ok"
      assert EdgeHeadersSim.verify_edge_headers(https_conn) == :ok
    end

    test "verify_edge_headers/2 detects missing or mismatched headers (anti-vacuity)" do
      missing = conn(:get, "https://agents.fnox.io/")
      assert {:error, failures} = EdgeHeadersSim.verify_edge_headers(missing)
      assert length(failures) == 3

      wrong_coep =
        conn(:get, "https://agents.fnox.io/")
        |> EdgeHeadersSim.call([])
        |> put_resp_header("cross-origin-embedder-policy", "unsafe-none")

      assert {:error,
              [{"cross-origin-embedder-policy", {:mismatch, "credentialless", "unsafe-none"}}]} =
               EdgeHeadersSim.verify_edge_headers(wrong_coep)
    end
  end

  describe "real Bandit HTTP wire round-trip" do
    setup do
      {:ok, _} = Application.ensure_all_started(:inets)

      upstream = fn conn -> send_resp(conn, 200, "duckdb-aoq-ready") end
      opts = EdgeHeadersSim.init(plug: upstream)

      server =
        start_supervised!(
          {Bandit,
           plug: {EdgeHeadersSim, opts}, scheme: :http, port: 0, ip: :loopback, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, port: port}
    end

    test "wire 301 redirect on plain HTTP and wire edge headers when x-forwarded-proto=https", %{
      port: port
    } do
      url = ~c"http://127.0.0.1:#{port}/duckdb/boot?v=1"

      {:ok, {{_, 301, _}, redirect_headers, ~c""}} =
        :httpc.request(:get, {url, [{~c"host", ~c"agents.fnox.io"}]}, [autoredirect: false], [])

      redirect_map =
        Map.new(redirect_headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

      assert redirect_map["location"] == "https://agents.fnox.io/duckdb/boot?v=1"
      refute Map.has_key?(redirect_map, "cross-origin-opener-policy")

      {:ok, {{_, 200, _}, edge_headers, body}} =
        :httpc.request(
          :get,
          {url, [{~c"host", ~c"agents.fnox.io"}, {~c"x-forwarded-proto", ~c"https"}]},
          [],
          body_format: :binary
        )

      assert body == "duckdb-aoq-ready"
      assert :ok == EdgeHeadersSim.verify_edge_headers(edge_headers)
    end
  end
end
