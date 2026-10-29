# BOOTPROF cut #2 (RELCUT, NFR-FOOTPRINT): phased listener start court.
#
# Chicago discipline: real Application boots, real TCP connects against the
# real listeners - no mocks, no sleeps (bounded connect-polls on real
# observables). Three faces:
#
#   1. Default boot pins existing behavior: ALL listeners accept.
#   2. Deferred boot: front door (ARM/egress) accepts strictly before any
#      deferred listener (TLS twin, AMQP, MCP) binds - phasing via
#      handle_continue after a tick.
#   3. Deferred boot still reaches ALL listeners (phasing delays, never
#      removes - byte-identical end state).
#
# Faces 2/3 ride a real subprocess boot (`mix run --no-start
# scripts/deferred_boot_probe.exs`) because the running test app already
# owns this VM's boot; the probe is the same subject under the config gate.
defmodule Smalt.Test.Internal.DeferredListenersCourtTest do
  use ExUnit.Case, async: false

  @probe Path.expand("../../scripts/deferred_boot_probe.exs", __DIR__)
  @front [:arm, :egress]
  @deferred [:arm_tls, :amqp, :event_hubs, :mcp]

  test "default boot: all six listeners accept (existing behavior pinned)" do
    assert Smalt.Application.deferred_listeners?() == false

    Enum.each(@front ++ @deferred, fn key ->
      assert accept?(port_for(key)),
             "listener #{inspect(key)} on port #{port_for(key)} never accepted"
    end)
  end

  test "deferred boot: front door accepts before any deferred listener binds" do
    %{"deferred" => true, "accepted_ms" => ms} = run_probe("1")

    front_max =
      ms |> Map.take(Enum.map(@front, &to_string/1)) |> Map.values() |> Enum.max()

    deferred_min =
      ms |> Map.take(Enum.map(@deferred, &to_string/1)) |> Map.values() |> Enum.min()

    assert front_max < deferred_min,
           "front door (#{front_max}ms) must accept before deferred (#{deferred_min}ms)"

    # End state identical: every listener eventually accepts.
    assert map_size(ms) == 6
    assert Enum.all?(Map.values(ms), &is_integer/1)
  end

  test "default probe boot: all listeners accept, no phasing constraint" do
    %{"deferred" => false, "accepted_ms" => ms} = run_probe("0")
    assert map_size(ms) == 6
    assert Enum.all?(Map.values(ms), &is_integer/1)
  end

  defp run_probe(flag) do
    # Fixed per-run ports (config/test.exs honors SMALT_TEST_*_PORT): the
    # nested boot must not re-probe free ports while this parent app's
    # listeners churn the ephemeral range.
    env =
      Map.merge(
        %{"SMALT_DEFERRED_LISTENERS" => flag, "MIX_ENV" => "test"},
        ports_env()
      )

    {out, code} =
      System.cmd("mix", ["run", "--no-start", @probe], env: env, stderr_to_stdout: true)

    if code != 0 do
      flunk("probe exited #{code}: ...#{String.slice(out, -1200, 1200)}")
    end

    line =
      out
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find(&(&1 =~ ~s("deferred")))
      |> raise_missing_probe_line(out)

    Jason.decode!(line)
  end

  defp ports_env do
    Map.new(@front ++ @deferred, fn key ->
      {"SMALT_TEST_#{String.upcase(to_string(key))}_PORT", Integer.to_string(alloc_port())}
    end)
  end

  defp alloc_port do
    # Below the macOS ephemeral autoalloc range (49152+): a listen(0)-then-close
    # port inside that range is stolen by the parent VM's own outbound connects
    # between alloc and the nested boot's bind (witnessed eaddrinuse twice).
    do_alloc(3)
  end

  defp do_alloc(0), do: raise("could not allocate a free port below 40000")

  defp do_alloc(tries) do
    candidate = :rand.uniform(20_000) + 20_000

    case :gen_tcp.listen(candidate, [:binary, active: false]) do
      {:ok, sock} ->
        {:ok, port} = :inet.port(sock)
        :gen_tcp.close(sock)
        port

      {:error, _} ->
        do_alloc(tries - 1)
    end
  end

  defp raise_missing_probe_line(nil, out),
    do: flunk("probe emitted no JSON line; output: #{inspect(out)}")

  defp raise_missing_probe_line(line, _out), do: line

  defp port_for(:arm), do: Application.fetch_env!(:smalt, :arm_port)
  defp port_for(:egress), do: Application.fetch_env!(:smalt, :egress_port)
  defp port_for(:arm_tls), do: Application.fetch_env!(:smalt, :arm_tls_port)
  defp port_for(:amqp), do: Application.fetch_env!(:smalt, :amqp_port)

  defp port_for(:event_hubs), do: Application.fetch_env!(:smalt, :event_hubs_port)
  defp port_for(:mcp), do: Application.fetch_env!(:smalt, :mcp_port)

  # Bounded connect-poll (no sleeps): retry the real TCP connect until the
  # listener accepts or the deadline lapses.
  defp accept?(port) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    poll(port, deadline)
  end

  defp poll(port, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 250) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          poll(port, deadline)
        end
    end
  end
end
