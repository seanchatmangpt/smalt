defmodule Smalt.AdaptiveHealthTest do
  use ExUnit.Case, async: false

  @describetag :health

  test "readiness is ready on a healthy substrate with all four checks" do
    {:ready, checks} = Smalt.Health.readiness()
    assert [:cluster, :memory, :scheduler, :store] == checks |> Map.keys() |> Enum.sort()
    assert checks.store == :ok
    assert checks.memory == :ok
    assert is_map(checks.scheduler)
    assert is_map(checks.cluster)
  end

  test "degrades on structural memory-bound breach, not on scheduler load" do
    Application.put_env(:smalt, Smalt.Health, processes_memory_high_water_bytes: 1)

    on_exit(fn -> Application.delete_env(:smalt, Smalt.Health) end)

    assert {:degraded, %{memory: {:error, {:processes_memory_over_high_water, _, 1}}}} =
             Smalt.Health.readiness()
  end

  test "liveness never fails on load" do
    assert :alive = Smalt.Health.liveness()
  end

  test "http_status: 200 ready / 503 degraded" do
    assert 200 = Smalt.Health.http_status({:ready, %{}})
    assert 503 = Smalt.Health.http_status({:degraded, %{}})
  end

  test "HealthPlug routes GET /healthz, /healthz/live, passes everything else through" do
    ready = Smalt.HealthPlug.call(%{Plug.Test.conn("GET", "/healthz") | path_info: ["healthz"]}, nil)
    assert ready.status == 200
    assert %{"status" => "ready"} = Jason.decode!(ready.resp_body)

    live =
      Smalt.HealthPlug.call(%{Plug.Test.conn("GET", "/healthz/live") | path_info: ["healthz", "live"]}, nil)

    assert live.status == 200

    other = Smalt.HealthPlug.call(%{Plug.Test.conn("GET", "/api/x") | path_info: ["api", "x"]}, nil)
    assert other.state == :unset
  end

  test "scheduler_capacity reports a mode and never raises under load" do
    m = Smalt.Health.scheduler_capacity()
    assert m.mode in [:run_queue, :scheduler_wall_time]
    assert is_integer(m.schedulers_online) and m.schedulers_online > 0
  end

  test "store_integrity is :ok when Store is alive with all tables present" do
    assert :ok = Smalt.Health.store_integrity()
  end
end
