defmodule Smalt.Integration.CorsHeadersKnobTest do
  # Chicago-style plug-conn court for the CORS headers knobs (lane S2,
  # v26.10.20): real CORSPlug preflights through the real routers — no mocks,
  # assertions on the wire response headers themselves.
  use ExUnit.Case, async: false

  @origin "https://popcorn.local"
  @req_headers "authorization,x-ms-documentdb-partitionkey"

  # ---------------------------------------------------------------------------
  # arm_cors (:smalt, :arm_cors_headers — lib/smalt/arm_gateway/router.ex)
  # ---------------------------------------------------------------------------

  defp arm_preflight do
    conn =
      Plug.Test.conn("OPTIONS", "/metadata/endpoints")
      |> Map.put(:req_headers, [
        {"origin", @origin},
        {"access-control-request-method", "GET"},
        {"access-control-request-headers", @req_headers}
      ])

    Smalt.ArmGateway.Router.call(conn, [])
  end

  test "arm router preflight echoes requested headers (default [\"*\"]) via real CORSPlug" do
    conn = arm_preflight()

    assert conn.status == 204
    assert {"access-control-allow-origin", "*"} in conn.resp_headers

    {:ok, allow_headers} =
      Enum.find_value(conn.resp_headers, {:ok, nil}, fn
        {"access-control-allow-headers", v} -> {:ok, v}
        _ -> nil
      end)

    # CORSPlug with headers ["*"] echoes the browser's
    # Access-Control-Request-Headers back verbatim.
    assert allow_headers == @req_headers
  end

  test "arm router honors an explicit :arm_cors_headers allowlist" do
    original = Application.get_env(:smalt, :arm_cors_headers)
    Application.put_env(:smalt, :arm_cors_headers, ["authorization", "x-ms-version"])

    on_exit(fn ->
      if original, do: Application.put_env(:smalt, :arm_cors_headers, original),
        else: Application.delete_env(:smalt, :arm_cors_headers)
    end)

    conn = arm_preflight()

    assert conn.status == 204

    allow_headers =
      conn.resp_headers
      |> Enum.find_value(fn
        {"access-control-allow-headers", v} -> v
        _ -> nil
      end)

    assert allow_headers == "authorization,x-ms-version"
  end

  # ---------------------------------------------------------------------------
  # egress_cors (:smalt, :egress_cors_headers — lib/smalt/egress_router.ex)
  # on a NON-blob plane path (kv prefix), so the static CORSPlug face applies.
  # ---------------------------------------------------------------------------

  defp egress_preflight(path) do
    conn =
      Plug.Test.conn("OPTIONS", path)
      |> Map.put(:req_headers, [
        {"origin", @origin},
        {"access-control-request-method", "GET"},
        {"access-control-request-headers", @req_headers}
      ])

    Smalt.EgressRouter.call(conn, [])
  end

  test "egress router preflight echoes requested headers (default [\"*\"]) on a non-blob path" do
    conn = egress_preflight("/keys/test-key")

    assert conn.status == 204
    assert {"access-control-allow-origin", "*"} in conn.resp_headers

    allow_headers =
      conn.resp_headers
      |> Enum.find_value(fn
        {"access-control-allow-headers", v} -> v
        _ -> nil
      end)

    assert allow_headers == @req_headers
  end

  test "egress router honors an explicit :egress_cors_headers allowlist" do
    original = Application.get_env(:smalt, :egress_cors_headers)
    Application.put_env(:smalt, :egress_cors_headers, ["authorization", "x-ms-keyvault-networkinfo"])

    on_exit(fn ->
      if original, do: Application.put_env(:smalt, :egress_cors_headers, original),
        else: Application.delete_env(:smalt, :egress_cors_headers)
    end)

    conn = egress_preflight("/keys/test-key")

    assert conn.status == 204

    allow_headers =
      conn.resp_headers
      |> Enum.find_value(fn
        {"access-control-allow-headers", v} -> v
        _ -> nil
      end)

    assert allow_headers == "authorization,x-ms-keyvault-networkinfo"
  end
end
