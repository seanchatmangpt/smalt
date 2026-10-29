defmodule Smalt.Egress.LatencyCourtTest do
  @moduledoc """
  Latency-realism court (lane 10): config-gated added latency on the egress
  listener.

  Cells:
  - config-OFF is ratio-fenced zero-overhead: min-of-5 real timings of the
    gated-but-off listener vs a bare-router baseline, ratio <= 1.5x (no
    sleeps in the fence — the timing is the measurement itself).
  - config-ON 800ms: the response is genuinely delayed (witnessed by real
    elapsed time) and a real TCP client with a short receive timeout gets a
    typed `{:error, :timeout}` (client-side timeout exercisable).
  - per-plane map: delay lands on the configured plane's paths only.
  - `delay_ms/2` sampling: p50 with prob 0.99, p99 tail on the complement,
    deterministic under an injected RNG.
  """

  use ExUnit.Case, async: false

  alias Smalt.Egress.LatencyPlug

  @moduletag :integration

  # Tail draw used to pin the RNG onto the p99 point.
  @tail 1.0

  setup do
    # Lane default restored after every cell; no leakage across tests.
    on_exit(fn -> Application.put_env(:smalt, :latency, :off) end)
    :ok
  end

  describe "config-off zero-overhead fence" do
    @tag :latency_court
    test "gated-off listener is <= 1.5x a bare-router baseline (min-of-5)" do
      baseline_port = start_listener(Smalt.EgressRouter)
      gated_port = start_listener({LatencyPlug, []})
      assert Application.get_env(:smalt, :latency) == :off

      baseline_ms = min_of_5(baseline_port)
      gated_ms = min_of_5(gated_port)
      ratio = gated_ms / max(baseline_ms, 1)

      assert gated_ms <= 1.5 * baseline_ms,
             "config-off overhead: baseline min #{baseline_ms}ms vs gated #{gated_ms}ms " <>
               "(ratio #{Float.round(ratio, 2)}x > 1.5x)"

      IO.puts(
        "  [latency-court] config-off fence: baseline=#{baseline_ms}ms gated=#{gated_ms}ms " <>
          "ratio=#{Float.round(ratio, 2)}x (<=1.5x)"
      )
    end
  end

  describe "config-on delayed response" do
    @tag :latency_court
    test "800ms p50: response witnessed delayed and client timeout fires typed" do
      port =
        start_listener({LatencyPlug, []}, p50_ms: 800, p99_ms: 1600, rng: fn -> 0.0 end)

      {elapsed_ms, {:ok, status, _body}} = timed_request(port, "/", timeout: 15_000)
      assert status in 200..499

      # Witness: the response took at least the sampled delay.
      assert elapsed_ms >= 800, "expected >= 800ms, witnessed #{elapsed_ms}ms"

      # Real client gives up long before the server answers: typed timeout.
      assert {:error, :timeout} = request(port, "/", timeout: 200)

      IO.puts(
        "  [latency-court] config-on: witnessed #{elapsed_ms}ms delay; " <>
          "client timeout typed {:error, :timeout}"
      )
    end

    @tag :latency_court
    test "p99 tail is samplable deterministically" do
      port =
        start_listener({LatencyPlug, []}, p50_ms: 800, p99_ms: 1600, rng: fn -> @tail end)

      {elapsed_ms, _} = timed_request(port, "/", timeout: 15_000)

      assert elapsed_ms >= 1600, "expected >= 1600ms (p99 draw), witnessed #{elapsed_ms}ms"
    end
  end

  describe "per-plane map" do
    @tag :latency_court
    test "delay lands on the configured plane only" do
      port =
        start_listener({LatencyPlug, []},
          p50_ms: 0,
          p99_ms: 0,
          planes: %{"keys" => [p50_ms: 400, p99_ms: 800]},
          rng: fn -> 0.0 end
        )

      # /keys/* is the delayed plane.
      {keys_ms, _} = timed_request(port, "/keys/probe", timeout: 15_000)
      assert keys_ms >= 400, "keys plane expected >= 400ms, witnessed #{keys_ms}ms"

      # Any other plane is undelayed (sampled 0).
      {root_ms, _} = timed_request(port, "/", timeout: 15_000)
      assert root_ms < 400, "default plane expected < 400ms, witnessed #{root_ms}ms"
    end
  end

  describe "sampling" do
    @tag :latency_court
    test "delay_ms/2 samples p50 with prob 0.99 and p99 on the complement" do
      assert LatencyPlug.delay_ms(:_, %{p50_ms: 100, p99_ms: 900, rng: fn -> 0.0 end}) == 100
      assert LatencyPlug.delay_ms(:_, %{p50_ms: 100, p99_ms: 900, rng: fn -> 0.98 end}) == 100
      assert LatencyPlug.delay_ms(:_, %{p50_ms: 100, p99_ms: 900, rng: fn -> 0.99 end}) == 900
      assert LatencyPlug.delay_ms(:_, %{p50_ms: 100, p99_ms: 900, rng: fn -> 1.0 end}) == 900
    end

    @tag :latency_court
    test "plane_of/1 keys on the first path segment" do
      assert LatencyPlug.plane_of("/keys/k1/versions") == "keys"
      assert LatencyPlug.plane_of("/dbs/x/colls") == "dbs"
      assert LatencyPlug.plane_of("/") == :_
      assert LatencyPlug.plane_of("/keys") == "keys"
    end
  end

  ##
  ## Harness — raw HTTP/1.0 client over :gen_tcp (real transport, real
  # timeout: `recv` bounded returns the typed {:error, :timeout} exactly
  # when the server has not answered within the budget).
  ##

  defp start_listener(plug, latency_cfg \\ :off) do
    Application.put_env(:smalt, :latency, latency_cfg)
    port = free_port()

    start_supervised!({Bandit, plug: plug, scheme: :http, port: port, ip: {127, 0, 0, 1}})

    port
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, port: 0)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Min-of-5 real timings (sleep-free fence per no-sleep doctrine: the
  # timing IS the measurement; nothing coordinates by clock).
  defp min_of_5(port) do
    1..5
    |> Enum.map(fn _ -> elem(timed_request(port, "/", timeout: 15_000), 0) end)
    |> Enum.min()
  end

  defp timed_request(port, path, timeout: timeout_ms) do
    start = System.monotonic_time(:millisecond)
    result = request(port, path, timeout: timeout_ms)
    {System.monotonic_time(:millisecond) - start, result}
  end

  defp request(port, path, timeout: timeout_ms) do
    # OTP 29: a :timeout entry inside connect's option list badargs — the
    # connect timeout is connect/5's fifth argument.
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], timeout_ms)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
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

      {:error, :closed} ->
        {:error, :closed}

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  defp status(headers) do
    case String.split(headers, " ", parts: 3) do
      [_, code | _] -> String.to_integer(code)
      _ -> 0
    end
  end
end
