defmodule Smalt.Integration.BkprobeHealthWireTest do
  use ExUnit.Case, async: false

  # BK-PROBE — BK-ARM1 F-1 closure: the k8s probes point at the real kernel
  # self-report. The router serves GET /.well-known/health/ready (200/503 per
  # Smalt.Health.readiness/0) and GET /.well-known/health/live (200 per
  # liveness/0) from the same process that serves ARM; the k8s manifests
  # (hand-written + .gen.yaml + priv/smalt-k8s.ttl probe blocks) point the
  # readinessProbe/livenessProbe httpGet paths at these faces. Kubelet probes
  # are tokenless: the paths sit in the /.well-known/ bearer-exempt namespace,
  # asserted here in :enforce auth mode with no token.
  #
  # Chicago: real router, real Store, real Health checks — the degraded leg
  # flips the module's documented bound seam (Application env
  # :smalt, Smalt.Health) to force a REAL structural degradation (ets memory
  # past high-water), not a mock. The kubelet-as-supervisor contract: a
  # degraded pod answering 503 on ready is removed from Service rotation /
  # restarted by kubelet instead of serving forever behind an always-200 face.

  alias Plug.Conn
  import Plug.Test

  defp dispatch(conn), do: Smalt.ArmGateway.Router.call(conn, [])

  test "healthy readiness: 200 ready with per-check map through the real router + store" do
    conn =
      :get
      |> conn("/.well-known/health/ready")
      |> dispatch()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ready"

    assert %{"scheduler" => %{}, "store" => "ok", "memory" => "ok"} =
             body["checks"] |> Map.take(["scheduler", "store", "memory"])
  end

  test "degraded readiness: 503 degraded when a structural check fails (ets memory over bound)" do
    prev = Application.get_env(:smalt, Smalt.Health)

    # REAL degraded state via the module's documented bound seam: zero the
    # ets high-water so the actual :erlang.memory(:ets) reading is over bound.
    Application.put_env(:smalt, Smalt.Health, ets_memory_high_water_bytes: 0)

    conn =
      :get
      |> conn("/.well-known/health/ready")
      |> dispatch()

    assert conn.status == 503
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "degraded"
    assert body["checks"]["memory"]["error"] =~ "ets_memory_over_high_water"

    Application.put_env(:smalt, Smalt.Health, prev)
  end

  test "liveness face: 200 alive" do
    conn =
      :get
      |> conn("/.well-known/health/live")
      |> dispatch()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "alive"}
  end

  test "probe faces are bearer-exempt: tokenless request in :enforce mode is NOT a 401" do
    prev = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :enforce)

    ready =
      :get
      |> conn("/.well-known/health/ready")
      |> dispatch()

    live =
      :get
      |> conn("/.well-known/health/live")
      |> dispatch()

    Application.put_env(:smalt, :auth_mode, prev)

    refute ready.status == 401
    refute live.status == 401
    assert ready.status == 200
    assert live.status == 200
  end
end
