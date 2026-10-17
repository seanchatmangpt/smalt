defmodule Smalt.ArmCorsTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  setup do
    on_exit(fn -> Application.delete_env(:smalt, :arm_cors_origins) end)
    :ok
  end

  defp get(path, origin) do
    conn = conn(:get, path, nil)
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    Smalt.ArmGateway.Router.call(conn, [])
  end

  test "default posture echoes any origin (allow-list ['*'])" do
    conn = get("/subscriptions?api-version=2020-01-01", "https://console.example")
    acao = get_resp_header(conn, "access-control-allow-origin")
    assert acao == ["*"]
  end

  test "allow-listed origin is echoed; disallowed origin gets no ACAO" do
    Application.put_env(:smalt, :arm_cors_origins, ["https://console.example"])

    allowed = get("/subscriptions?api-version=2020-01-01", "https://console.example")
    assert get_resp_header(allowed, "access-control-allow-origin") == ["https://console.example"]

    denied = get("/subscriptions?api-version=2020-01-01", "https://evil.example")
    assert get_resp_header(denied, "access-control-allow-origin") == []
  end

  test "config flip needs no recompile (per-request evaluation)" do
    conn = get("/subscriptions?api-version=2020-01-01", "https://console.example")
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

    Application.put_env(:smalt, :arm_cors_origins, ["https://console.example"])
    conn2 = get("/subscriptions?api-version=2020-01-01", "https://console.example")
    assert get_resp_header(conn2, "access-control-allow-origin") == ["https://console.example"]
  end
end
