defmodule Smalt.HealthProbeParityTest do
  @moduledoc """
  W30-I adoption (Z4, test-first): the vNext health-probe candidate adds
  `version` (smalt app vsn) + `timestamp` (ISO8601 UTC) to probe bodies.

  Parity note (W30-I): smalt keeps its STRUCTURAL verdict model — readiness
  stays `{"status": "ready"|"degraded", ...checks}` and does NOT adopt the
  vNext boolean `overall` collapse (strictly stronger: checks stay visible).
  """

  use ExUnit.Case, async: false

  @describetag :health

  import Plug.Test

  defp get(path, path_info) do
    Smalt.HealthPlug.call(%{conn("GET", path) | path_info: path_info}, nil)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "GET /healthz carries version + timestamp alongside structural verdict" do
    conn = get("/healthz", ["healthz"])
    assert conn.status == 200

    body = decode(conn)
    assert body["status"] == "ready"
    assert body["checks"]["store"] == "ok"

    # new fields
    assert is_binary(body["version"]) and body["version"] != ""
    assert body["version"] == to_string(Application.spec(:smalt, :vsn))

    {:ok, %DateTime{}, 0} = DateTime.from_iso8601(body["timestamp"])
  end

  test "GET /healthz/live carries version + timestamp with status alive" do
    conn = get("/healthz/live", ["healthz", "live"])
    assert conn.status == 200

    body = decode(conn)
    assert body["status"] == "alive"
    assert body["version"] == to_string(Application.spec(:smalt, :vsn))
    {:ok, %DateTime{}, 0} = DateTime.from_iso8601(body["timestamp"])
  end

  test "degraded readiness keeps 503 and structural checks; new fields present" do
    Application.put_env(:smalt, Smalt.Health, processes_memory_high_water_bytes: 1)
    on_exit(fn -> Application.delete_env(:smalt, Smalt.Health) end)

    conn = get("/healthz", ["healthz"])
    assert conn.status == 503

    body = decode(conn)
    assert body["status"] == "degraded"
    assert body["checks"]["memory"]["error"] =~ "processes_memory_over_high_water"
    assert is_binary(body["version"])
    {:ok, %DateTime{}, 0} = DateTime.from_iso8601(body["timestamp"])
  end

  test "no-Origin requests stay CORS-clean (no allow-origin header)" do
    conn = get("/healthz", ["healthz"])
    refute Plug.Conn.get_resp_header(conn, "access-control-allow-origin") != []
  end

  test "no-auth: health answers without any bearer token" do
    # probe path must not require auth — conn carries no authorization header
    conn = get("/healthz", ["healthz"])
    assert conn.status in [200, 503]
  end

  test "readiness verdict shape is unchanged structurally (no boolean overall collapse)" do
    {:ready, checks} = Smalt.Health.readiness()
    assert is_map(checks) and map_size(checks) == 4
    assert [:cluster, :memory, :scheduler, :store] == checks |> Map.keys() |> Enum.sort()
  end
end
