defmodule Smalt.Integration.ControlPlaneRealismTest do
  @moduledoc """
  AZURE-FIDELITY lane 18 court: throttle/latency realism on the ARM
  control-plane routes.

  Cells:
  - plane-map keys match the actual route prefixes (deployments / graph /
    cost classified from real route paths, literal from
    `Smalt.ArmGateway.Router`'s route list).
  - gate-OFF is ratio-fenced zero-overhead: min-of-5 real timings of the
    gated-but-off plug vs the bare `ArmGateway.Router` baseline, ratio
    <= 1.5x (no sleeps in the fence — the timing is the measurement).
  - gate-ON: a deployment PUT/status-poll is genuinely delayed (witnessed by
    real elapsed time) and a real TCP client with a short receive timeout
    gets a typed `{:error, :timeout}`.
  - ARM route classes absent from the configured `:planes` map fall back to
    the built-in class profile (cost 150/400, graph 60/150).
  - throttle: exhausting the :deployments class bucket answers the real ARM
    429 TooManyRequests envelope with retry-after on the wire.
  """

  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Smalt.Egress.LatencyPlug
  alias Smalt.Egress.ThrottlePlug
  alias Smalt.ArmGateway.Router, as: Arm

  @moduletag :integration

  setup do
    prev_latency = Application.get_env(:smalt, :latency)
    prev_throttle = Application.get_env(:smalt, :throttle)
    prev_clock = Application.get_env(:smalt, :throttle_clock)

    on_exit(fn ->
      Application.put_env(:smalt, :latency, prev_latency)
      Application.put_env(:smalt, :throttle, prev_throttle)
      Application.put_env(:smalt, :throttle_clock, prev_clock)
      ThrottlePlug.reset!()
    end)

    :ok
  end

  # -- plane map keys match the actual route prefixes -----------------------------

  describe "plane-map keys vs route prefixes" do
    @tag :control_plane_realism
    test "latency plane_of classifies the ARM control-plane route classes" do
      # Literal paths from ArmGateway.Router's route list.
      assert LatencyPlug.plane_of(
               "/subscriptions/sub-1/resourcegroups/rg1/providers/Microsoft.Resources/deployments/d1"
             ) == "deployments"

      assert LatencyPlug.plane_of(
               "/subscriptions/sub-1/resourceGroups/rg1/providers/Microsoft.Resources/deployments/d1/operations"
             ) == "deployments"

      assert LatencyPlug.plane_of("/providers/Microsoft.ResourceGraph/resources") == "graph"

      assert LatencyPlug.plane_of(
               "/subscriptions/sub-1/providers/Microsoft.CostManagement/query"
             ) == "cost"

      # Non-ARM planes keep first-segment keys (unchanged behavior).
      assert LatencyPlug.plane_of("/keys/k1/versions") == "keys"
      assert LatencyPlug.plane_of("/dbs/db1/colls") == "dbs"
      assert LatencyPlug.plane_of("/") == :_

      # ARM shapes outside the three classes stay on the catch-all plane.
      assert LatencyPlug.plane_of("/subscriptions/sub-1/resourcegroups") == :_
    end
  end

  # -- gate-off: zero-overhead ratio fence ------------------------------------------

  describe "config-off zero-overhead fence" do
    @tag :control_plane_realism
    test "gated-off ARM path is <= 1.5x the bare-router baseline (min-of-5)" do
      Application.put_env(:smalt, :latency, :off)
      assert Application.get_env(:smalt, :latency) == :off

      path = deployment_put_path()

      baseline_us = min_of_5(fn -> arm(Arm, "PUT", path) end)
      gated_us = min_of_5(fn -> arm(LatencyPlug, "PUT", path) end)
      ratio = gated_us / max(baseline_us, 1)

      assert gated_us <= 1.5 * baseline_us,
             "config-off overhead: baseline min #{baseline_us}µs vs gated #{gated_us}µs " <>
               "(ratio #{Float.round(ratio, 2)}x > 1.5x)"

      IO.puts(
        "  [control-plane-realism] config-off fence: baseline=#{baseline_us}µs " <>
          "gated=#{gated_us}µs ratio=#{Float.round(ratio, 2)}x (<=1.5x)"
      )
    end
  end

  # -- gate-on: deployment-poll delay witnessed, client timeout typed ----------------

  describe "config-on deployment delay" do
    @tag :control_plane_realism
    test "deployment PUT witnessed delayed by the class profile" do
      arm_latency(
        planes: %{"deployments" => [p50_ms: 400, p99_ms: 800]},
        rng: fn -> 0.0 end
      )

      {elapsed_ms, conn} = timed(fn -> arm(LatencyPlug, "PUT", deployment_put_path()) end)

      # The router answered (401 bearer-guarded is fine — the WITNESS is the
      # elapsed time, not the status).
      assert conn.status in 200..599
      assert elapsed_ms >= 400, "expected >= 400ms, witnessed #{elapsed_ms}ms"

      IO.puts(
        "  [control-plane-realism] gate-on deployment PUT: witnessed #{elapsed_ms}ms " <>
          "(>= p50 400ms)"
      )
    end

    @tag :control_plane_realism
    test "real TCP client with a short receive timeout gets a typed timeout" do
      port =
        start_listener(
          planes: %{"deployments" => [p50_ms: 800, p99_ms: 1600]},
          rng: fn -> 0.0 end
        )

      assert {:error, :timeout} = tcp_request(port, deployment_put_path(), timeout: 200)
    end

    @tag :control_plane_realism
    test "non-deployment path is not delayed by the deployments profile" do
      arm_latency(
        planes: %{"deployments" => [p50_ms: 400, p99_ms: 800]},
        rng: fn -> 0.0 end
      )

      {elapsed_ms, _} = timed(fn -> arm(LatencyPlug, "GET", "/subscriptions/sub-1/resourcegroups") end)
      assert elapsed_ms < 400, "catch-all plane expected < 400ms, witnessed #{elapsed_ms}ms"
    end
  end

  # -- built-in class profile fallback ------------------------------------------------

  describe "built-in ARM class profiles" do
    @tag :control_plane_realism
    test "classes absent from :planes fall back to the built-in profile" do
      # Arming via the deployments key alone; cost/graph come from the
      # built-in profile.
      arm_latency(
        planes: %{"deployments" => [p50_ms: 250, p99_ms: 800]},
        rng: fn -> 0.0 end
      )

      {cost_ms, _} =
        timed(fn -> arm(LatencyPlug, "POST", "/subscriptions/sub-1/providers/Microsoft.CostManagement/query") end)

      assert cost_ms >= 150, "cost class expected >= 150ms (built-in p50), witnessed #{cost_ms}ms"

      {graph_ms, _} = timed(fn -> arm(LatencyPlug, "POST", "/providers/Microsoft.ResourceGraph/resources") end)

      assert graph_ms >= 60, "graph class expected >= 60ms (built-in p50), witnessed #{graph_ms}ms"

      IO.puts(
        "  [control-plane-realism] built-in profiles: cost=#{cost_ms}ms (>=150) " <>
          "graph=#{graph_ms}ms (>=60)"
      )
    end

    @tag :control_plane_realism
    test "explicit :planes entries override the built-in profile" do
      arm_latency(
        planes: %{"cost" => [p50_ms: 500, p99_ms: 900]},
        rng: fn -> 0.0 end
      )

      {cost_ms, _} =
        timed(fn -> arm(LatencyPlug, "POST", "/subscriptions/sub-1/providers/Microsoft.CostManagement/query") end)

      assert cost_ms >= 500, "explicit cost profile expected >= 500ms, witnessed #{cost_ms}ms"
    end
  end

  # -- throttle: typed ARM 429 face ----------------------------------------------------

  describe "control-plane throttling" do
    @tag :control_plane_realism
    test "exhausted deployments class answers the ARM TooManyRequests envelope" do
      Application.put_env(:smalt, :throttle, rate: 1, burst: 2)
      ThrottlePlug.reset!()

      # Drain the :deployments bucket directly (deterministic, no sleeps);
      # the wire request below is the exhausting one.
      for _ <- 1..2 do
        assert elem(ThrottlePlug.take_token(:deployments, "subscriptions", 1, 2, now_ms()), 0)
      end

      conn =
        "PUT"
        |> Plug.Test.conn(deployment_put_path())
        |> ThrottlePlug.call([])

      assert conn.status == 429
      assert [ra] = get_resp_header(conn, "retry-after")
      assert String.to_integer(ra) >= 1

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "TooManyRequests"
      assert conn.resp_body =~ "deployments"

      # Through the real router chain the throttle runs before dispatch; the
      # gate-off default leaves the chain untouched.
      Application.put_env(:smalt, :throttle, rate: nil, burst: nil)

      conn2 =
        "PUT"
        |> Plug.Test.conn(deployment_put_path())
        |> ThrottlePlug.call([])

      refute conn2.status == 429
      assert get_resp_header(conn2, "retry-after") == []
    end

    @tag :control_plane_realism
    test "buckets are per-class: draining deployments does not throttle graph" do
      Application.put_env(:smalt, :throttle, rate: 1, burst: 1)

      for _ <- 1..1 do
        assert elem(ThrottlePlug.take_token(:deployments, "subscriptions", 1, 1, now_ms()), 0)
      end

      assert elem(ThrottlePlug.take_token(:graph, "subscriptions", 1, 1, now_ms()), 0)
    end
  end

  # -- harness -------------------------------------------------------------------------

  defp arm_latency(cfg), do: Application.put_env(:smalt, :latency, cfg)

  defp deployment_put_path do
    "/subscriptions/sub-1/resourcegroups/rg1/providers/Microsoft.Resources/deployments/d1"
  end

  # Real plug chain: the conn runs through the actual router (bearer guard
  # answers 401 when unauthenticated — the response proves dispatch ran).
  defp arm(plug, method, path) do
    method
    |> Plug.Test.conn(path)
    |> plug.call(router_opts(plug))
  end

  defp router_opts(LatencyPlug), do: [router: Arm]
  defp router_opts(_bare_router), do: []

  defp timed(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
  end

  # The fence needs sub-ms resolution: ms-floor timings would witness
  # 0ms-vs-0ms, a vacuous 0.0x ratio.
  defp timed_us(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - start, result}
  end

  defp min_of_5(fun) do
    1..5 |> Enum.map(fn _ -> elem(timed_us(fun), 0) end) |> Enum.min()
  end

  defp now_ms, do: System.system_time(:millisecond)

  # Real HTTP/1.0 over :gen_tcp — recv's bound is the client timeout; the
  # typed {:error, :timeout} fires exactly when the server has not answered.
  defp start_listener(latency_cfg) do
    Application.put_env(:smalt, :latency, latency_cfg)
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {LatencyPlug, [router: Arm]}, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    port
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, port: 0)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp tcp_request(port, path, timeout: timeout_ms) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], timeout_ms)

    :ok =
      :gen_tcp.send(
        socket,
        "PUT #{path} HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      )

    loop(socket, "", timeout_ms)
  end

  defp loop(socket, buf, timeout_ms) do
    case :gen_tcp.recv(socket, 0, timeout_ms) do
      {:ok, data} ->
        buf = <<buf::binary, data::binary>>

        case :binary.split(buf, "\r\n\r\n") do
          [headers, body] ->
            :gen_tcp.close(socket)
            {:ok, status(headers), body}

          _ ->
            loop(socket, buf, timeout_ms)
        end

      {:error, _} = err ->
        :gen_tcp.close(socket)
        err
    end
  end

  defp status(headers) do
    case :binary.split(headers, " ") do
      [_, rest] -> rest |> String.split(" ") |> hd() |> String.to_integer()
      _ -> 0
    end
  end
end
