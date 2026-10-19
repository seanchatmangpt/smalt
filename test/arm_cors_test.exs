defmodule Smalt.ArmCorsTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  setup do
    # Canonical save+on_exit restore (SmaltTest.Env), capture-then-delete:
    # the key is ABSENT for the test body (the router's ["*"] default) and the
    # on_exit restores presence exactly — an absent pre-test key is delete_env'd,
    # a pre-existing one put back verbatim.
    SmaltTest.Env.put_restored(
      arm_cors_origins: Application.get_env(:smalt, :arm_cors_origins)
    )
    Application.delete_env(:smalt, :arm_cors_origins)
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
    SmaltTest.Env.put_restored(arm_cors_origins: ["https://console.example"])

    allowed = get("/subscriptions?api-version=2020-01-01", "https://console.example")
    assert get_resp_header(allowed, "access-control-allow-origin") == ["https://console.example"]

    denied = get("/subscriptions?api-version=2020-01-01", "https://evil.example")
    assert get_resp_header(denied, "access-control-allow-origin") == []
  end

  test "config flip needs no recompile (per-request evaluation)" do
    conn = get("/subscriptions?api-version=2020-01-01", "https://console.example")
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

    SmaltTest.Env.put_restored(arm_cors_origins: ["https://console.example"])
    conn2 = get("/subscriptions?api-version=2020-01-01", "https://console.example")
    assert get_resp_header(conn2, "access-control-allow-origin") == ["https://console.example"]
  end
end
