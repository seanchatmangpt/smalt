defmodule Smalt.ServengineSim.WsOriginGuardTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Smalt.ServengineSim.WsOriginGuard
  alias Smalt.ServengineSim.WsOriginGuard.Endpoint

  @endpoint_opts Endpoint.init([])
  @valid_hosts ["xaas.fnox.io", "servengine.fnox.io", "servegine.fnox.io"]
  @socket_paths ["/live", "/live/websocket", "/live/longpoll", "/socket", "/socket/websocket"]

  setup do
    prior_phx_host = System.get_env("PHX_HOST")
    System.put_env("PHX_HOST", "xaas.fnox.io")

    on_exit(fn ->
      if prior_phx_host do
        System.put_env("PHX_HOST", prior_phx_host)
      else
        System.delete_env("PHX_HOST")
      end
    end)

    :ok
  end

  defp alb_conn(method, path, host, origin) do
    conn(method, "http://#{host}:4000#{path}")
    |> put_req_header("x-forwarded-proto", "https")
    |> put_req_header("x-forwarded-port", "443")
    |> put_req_header("x-forwarded-host", host)
    |> maybe_put_origin(origin)
  end

  defp maybe_put_origin(conn, nil), do: conn
  defp maybe_put_origin(conn, origin), do: put_req_header(conn, "origin", origin)

  describe "Endpoint behind ALB with PHX_HOST=xaas.fnox.io" do
    test "allows valid origins on /live and /socket paths" do
      for host <- @valid_hosts, path <- @socket_paths do
        origin = "https://#{host}"

        conn =
          :get
          |> alb_conn(path, host, origin)
          |> Endpoint.call(@endpoint_opts)

        assert conn.status == 200, "expected 200 for #{path} with origin #{origin}"
        refute conn.halted

        body = Jason.decode!(conn.resp_body)
        assert body["status"] == "admitted"
        assert body["phx_host"] == "xaas.fnox.io"
        assert body["origin"] == origin
        assert body["x_forwarded_proto"] == "https"
        assert body["x_forwarded_host"] == host
      end
    end

    test "allows case-insensitive host and explicit :443 port for valid hosts" do
      for {host, origin} <- [
            {"servengine.fnox.io", "https://SERVENGINE.FNOX.IO"},
            {"servegine.fnox.io", "https://servegine.fnox.io:443"},
            {"xaas.fnox.io", "https://xaas.fnox.io:443"}
          ],
          path <- ["/live/websocket", "/socket/websocket"] do
        conn =
          :get
          |> alb_conn(path, host, origin)
          |> Endpoint.call(@endpoint_opts)

        assert conn.status == 200
        refute conn.halted
      end
    end

    test "rejects evil.example with 403 and halts on /live and /socket" do
      for target_host <- @valid_hosts,
          path <- @socket_paths,
          bad_origin <- [
            "https://evil.example",
            "http://evil.example",
            "https://evil.example:443"
          ] do
        conn =
          :get
          |> alb_conn(path, target_host, bad_origin)
          |> Endpoint.call(@endpoint_opts)

        assert conn.status == 403, "expected 403 for #{path} origin #{bad_origin}"
        assert conn.halted
        assert conn.resp_body == ""
      end
    end

    test "rejects domain spoofing, scheme downgrade, wrong port, and hostless origins with 403" do
      bad_origins = [
        "https://servengine.fnox.io.evil.example",
        "https://evilservengine.fnox.io",
        "https://sub.servengine.fnox.io",
        "http://servengine.fnox.io",
        "http://servegine.fnox.io",
        "https://servengine.fnox.io:8443",
        "null",
        ""
      ]

      for path <- ["/live", "/socket"], origin <- bad_origins do
        conn =
          :get
          |> alb_conn(path, "servengine.fnox.io", origin)
          |> Endpoint.call(@endpoint_opts)

        assert conn.status == 403, "expected 403 for #{path} with origin #{inspect(origin)}"
        assert conn.halted
      end
    end

    test "does not origin-gate non-socket HTTP paths like /healthz or lookalike /livez" do
      for path <- ["/healthz", "/livez"] do
        conn =
          :get
          |> alb_conn(path, "servengine.fnox.io", "https://evil.example")
          |> Endpoint.call(@endpoint_opts)

        refute conn.status == 403
      end
    end
  end

  describe "Phoenix check_origin modes behind ALB" do
    test "check_origin: true (PHX_HOST only) admits xaas.fnox.io but rejects ALB virtual hosts 403" do
      opts = WsOriginGuard.init(check_origin: true)

      ok_conn =
        :get
        |> alb_conn("/live/websocket", "xaas.fnox.io", "https://xaas.fnox.io")
        |> WsOriginGuard.call(opts)

      refute ok_conn.halted

      for alb_host <- ["servengine.fnox.io", "servegine.fnox.io"] do
        rejected =
          :get
          |> alb_conn("/live/websocket", alb_host, "https://#{alb_host}")
          |> WsOriginGuard.call(opts)

        assert rejected.status == 403
        assert rejected.halted
      end
    end

    test "check_origin: :conn fails behind TLS-terminating ALB unless rewrite_on_alb: true" do
      raw_opts = WsOriginGuard.init(check_origin: :conn, rewrite_on_alb: false)
      rewritten_opts = WsOriginGuard.init(check_origin: :conn, rewrite_on_alb: true)

      raw_conn =
        :get
        |> alb_conn("/socket/websocket", "servengine.fnox.io", "https://servengine.fnox.io")
        |> WsOriginGuard.call(raw_opts)

      assert raw_conn.status == 403
      assert raw_conn.halted

      for host <- ["servengine.fnox.io", "servegine.fnox.io"] do
        ok_conn =
          :get
          |> alb_conn("/socket/websocket", host, "https://#{host}")
          |> WsOriginGuard.call(rewritten_opts)

        refute ok_conn.halted
      end

      evil_conn =
        :get
        |> alb_conn("/socket/websocket", "servengine.fnox.io", "https://evil.example")
        |> WsOriginGuard.call(rewritten_opts)

      assert evil_conn.status == 403
      assert evil_conn.halted
    end

    test "missing Origin header follows Phoenix default (allowed) unless require_origin: true" do
      default_opts = WsOriginGuard.init([])
      strict_opts = WsOriginGuard.init(require_origin: true)

      ok_conn =
        :get
        |> alb_conn("/socket/websocket", "servengine.fnox.io", nil)
        |> WsOriginGuard.call(default_opts)

      refute ok_conn.halted

      strict_conn =
        :get
        |> alb_conn("/socket/websocket", "servengine.fnox.io", nil)
        |> WsOriginGuard.call(strict_opts)

      assert strict_conn.status == 403
      assert strict_conn.halted
    end

    test "supports wildcard, scheme-relative, false, and MFA check_origin forms" do
      wildcard_opts = WsOriginGuard.init(check_origin: ["https://*.fnox.io", "//localhost:4000"])

      assert not WsOriginGuard.call(
               alb_conn(:get, "/live", "servengine.fnox.io", "https://servengine.fnox.io"),
               wildcard_opts
             ).halted

      assert WsOriginGuard.call(
               alb_conn(:get, "/live", "servengine.fnox.io", "https://evil.example"),
               wildcard_opts
             ).status == 403

      disabled_opts = WsOriginGuard.init(check_origin: false)

      refute WsOriginGuard.call(
               alb_conn(:get, "/socket", "servengine.fnox.io", "https://evil.example"),
               disabled_opts
             ).halted

      mfa_opts = WsOriginGuard.init(check_origin: {__MODULE__, :mfa_allow_fnox?, []})

      refute WsOriginGuard.call(
               alb_conn(:get, "/live", "servegine.fnox.io", "https://servegine.fnox.io"),
               mfa_opts
             ).halted

      assert WsOriginGuard.call(
               alb_conn(:get, "/live", "servegine.fnox.io", "https://evil.example"),
               mfa_opts
             ).status == 403
    end

    test "allowed_origins/1 reflects PHX_HOST env plus ALB virtual hosts" do
      assert WsOriginGuard.allowed_origins() == [
               "https://xaas.fnox.io",
               "https://servengine.fnox.io",
               "https://servegine.fnox.io"
             ]
    end
  end

  def mfa_allow_fnox?(%URI{scheme: "https", host: host})
      when host in ["xaas.fnox.io", "servengine.fnox.io", "servegine.fnox.io"],
      do: true

  def mfa_allow_fnox?(_uri), do: false
end
