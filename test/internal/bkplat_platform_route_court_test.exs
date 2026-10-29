# BK-PLATFORM-ROUTE court (v26.10.22): the platform pseudo-resource metric
# face on the metrics wire — BK-MON5 typed carry-forward
# PLATFORM-FACE-UNROUTED.
#
# Defect: the monitor accumulator keys non-ARM traffic and platform events
# under the 2-segment id `providers/Smalt.Monitor/platform` (no name
# segment); the metrics route family required 3 segments
# (`providers/:ns/:type/:name`), so wire GETs for the platform face answered
# 404 RouteNotFound while in-process series/5 on the platform key was
# coherent (bkmon5-metrics-verify.md, Probe 3).
#
# Fix: literal platform metric route
# `GET /subscriptions/_smalt_monitor/resourceGroups/_smalt_monitor/
# providers/Smalt.Monitor/platform/providers/microsoft.insights/metrics`
# serving the SAME series/5 accumulator path (exact downcased-equality
# join, bkmon3r law) via handle_metrics_platform/1. Real Azure Monitor
# exposes platform metric faces (Microsoft.Monitor platform shape), so the
# face is routed, not typed UNSUPPORTED.
#
# Chicago discipline: real :telemetry events into the real attached
# handler, real tuple-keyed ETS, real HTTP/1.1 over loopback against the
# self-booted ArmGateway.Router. No mocks, no sleeps. BK-MON6 integrity
# pattern: distinct per-metric seeded values, no cross-leak.
#
# Context: solo (internal tier, in-process wire faces).

defmodule Smalt.Test.Internal.BkplatPlatformRouteCourtTest do
  use ExUnit.Case, async: false

  @api "2021-04-01"

  @platform_path "/subscriptions/_smalt_monitor/resourceGroups/_smalt_monitor/providers/Smalt.Monitor/platform/providers/microsoft.insights/metrics"

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp base, do: "http://127.0.0.1:#{Application.get_env(:smalt, :arm_port)}"

  defp get(url) do
    :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)
    |> case do
      {:ok, {{_v, status, _phrase}, _hds, rsp}} -> {status, rsp}
      {:error, reason} -> flunk("httpc error on #{url}: #{inspect(reason)}")
    end
  end

  defp platform_metrics_url(metric),
    do: "#{base()}#{@platform_path}?api-version=#{@api}&metricnames=#{metric}"

  defp platform_get(metric) do
    {status, rsp} = get(platform_metrics_url(metric))
    assert status == 200, "expected 200 on the platform face, got #{status}: #{inspect(rsp)}"
    assert {:ok, %{"value" => value}} = Jason.decode(rsp)
    value
  end

  defp totals(value) do
    case value do
      [%{"timeseries" => [%{"data" => data}]}] ->
        data |> Enum.map(&Map.get(&1, "total")) |> Enum.reject(&is_nil/1) |> Enum.sum()

      [] ->
        0.0
    end
  end

  # Seed platform rows through the REAL emit sites: a bandit request on a
  # non-ARM path (platform attribution) and the egress-refused event.
  # :telemetry.execute is synchronous — rows are on the table on return.
  defp record_platform_requests(n) do
    :telemetry.execute(
      [:bandit, :request, :stop],
      %{duration: System.convert_time_unit(13, :millisecond, :native)},
      %{conn: %Plug.Conn{request_path: "/metadata/endpoints?api-version=x"}}
    )

    if n > 1, do: record_platform_requests(n - 1)
  end

  defp record_egress_refused do
    :telemetry.execute([:smalt, :egress, :refused], %{}, %{})
  end

  test "L1: platform face routed — Requests served from the accumulator (200, nonzero)" do
    record_platform_requests(3)

    value = platform_get("Requests")

    assert [%{"timeseries" => [%{"data" => data}]}] = value
    t = totals(value)

    assert t >= 3.0,
           "expected >= 3.0 platform Requests totals (3 seeded + boot traffic), got #{t}: #{inspect(data)}"
  end

  test "L2: BK-MON6 integrity — EgressRefused is independently addressable, no cross-leak into Requests" do
    record_platform_requests(2)
    record_egress_refused()

    refused = platform_get("EgressRefused") |> totals()
    requests = platform_get("Requests") |> totals()

    assert refused >= 1.0, "expected >= 1.0 EgressRefused, got #{inspect(refused)}"

    # Metric identity is echoed in the envelope — each query answers with
    # its OWN metric name (no cross-metric join), matching series/5.
    assert [%{"name" => %{"value" => "EgressRefused"}}] = platform_get("EgressRefused")
    assert [%{"name" => %{"value" => "Requests"}}] = platform_get("Requests")

    dur = platform_get("RequestDuration") |> totals()

    assert dur >= 26.0,
           "expected >= 26.0 RequestDuration (2 x 13ms seeded), got #{inspect(dur)}"
  end

  test "L3: metric with no platform rows answers the empty envelope (200)" do
    # A metric name the accumulator never produces for the platform.
    value = platform_get("NoSuchPlatformMetric")
    assert value == [], "expected empty envelope, got #{inspect(value)}"
  end

  test "L4: api-version gate still enforced on the platform face" do
    # Monotonic admission (KD-78 shape): any version <= latest is admitted,
    # so the refusal pin uses a FUTURE version (2099), never a past one.
    url =
      "#{base()}/subscriptions/_smalt_monitor/resourceGroups/_smalt_monitor/providers/Smalt.Monitor/platform/providers/microsoft.insights/metrics?api-version=2099-01-01&metricnames=Requests"

    {status, rsp} = get(url)

    assert status == 400, "expected 400 for future api-version, got #{status}: #{inspect(rsp)}"
  end
end
