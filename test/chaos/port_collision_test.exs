defmodule Smalt.Chaos.PortCollisionTest do
  @moduledoc """
  Fail-closed chaos tier: port collision.

  Boots the FULL application supervision tree on FREE ephemeral ports (probed
  with `:gen_tcp.listen(0)` then closed — the bind race is accepted), then
  attempts a SECOND boot over the SAME ports. The second boot must fail CLOSED:

    - a full-tree second `Smalt.Application.start/2` errors (already-started
      named children refuse a second named tree — no silent sharing);
    - a second Bandit child over the same port fails to bind (eaddrinuse) and
      the second supervisor returns an error instead of silently co-binding;

  and CRITICALLY the FIRST substrate keeps serving `GET /subscriptions` with
  200 over real `:gen_tcp` HTTP throughout — no mocks, no Plug.Test dispatch.
  """

  use ExUnit.Case, async: false

  @default_sub "00000000-0000-0000-0000-000000000000"

  setup do
    # Boot the full tree on the ephemeral ports, retrying on the accepted
    # probe-then-close bind race (a concurrent lane can claim a probed port).
    boot_with_retry()

    ports = %{
      arm: Application.get_env(:smalt, :arm_port),
      egress: Application.get_env(:smalt, :egress_port),
      amqp: Application.get_env(:smalt, :amqp_port),
      event_hubs: Application.get_env(:smalt, :event_hubs_port)
    }

    assert is_integer(ports.arm)
    assert_process_whereis(Smalt.Supervisor)

    on_exit(fn ->
      Application.stop(:smalt)

      # Restore on the suite's shifted ports (docs/TEST_ISOLATION.md section 2).
      # Restoring on the defaults would collide with a live substrate instance
      # holding them and leave the shared Store dead for every downstream
      # module in the run.
      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    {:ok, ports: ports}
  end

  test "second boot over the same ports fails closed, first substrate keeps serving", %{
    ports: ports
  } do
    # First substrate is serving on the ephemeral ARM port.
    assert {200, _body} = http_get(ports.arm, "/subscriptions?api-version=2021-04-01")

    # --- Fail-closed path 1: a second FULL application tree ---------------
    # Named children (Smalt.Store, Smalt.AmqpBroker, Smalt.Supervisor) already
    # exist, so the second boot must refuse, not silently attach.
    assert {:error, {:already_started, _}} = Smalt.Application.start(:normal, [])

    # First substrate still serving after the refused second boot.
    assert {200, _} = http_get(ports.arm, "/subscriptions?api-version=2021-04-01")

    # --- Fail-closed path 2: a second Bandit child over the SAME port -----
    # Fresh supervisor with unique name; identical Bandit child spec shape the
    # application uses (plug + port), pointed at the first tree's ARM port.
    second_sup = String.to_atom("Smalt.Chaos.SecondSup_#{System.unique_integer([:positive])}")

    # Start the second tree OUTSIDE the test process (it is linked to its
    # starter, and a bind failure must surface as a return value, not an EXIT
    # that kills the test).
    result =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, false)

        case Supervisor.start_link(
               [
                 {Bandit,
                  plug: Smalt.ArmGateway.Router,
                  scheme: :http,
                  # SHIM-COURT-style fail-closed pin: bind the SPECIFIC loopback
                  # address. Without `ip:` a wildcard (default) bind co-exists
                  # with the specific-address first listener on macOS
                  # (SO_REUSEADDR), silently returning {:ok, pid} instead of
                  # eaddrinuse.
                  ip: {127, 0, 0, 1},
                  port: ports.arm}
               ],
               strategy: :one_for_one,
               name: second_sup
             ) do
          {:ok, pid} ->
            # Fail-closed: a successful second bind is itself the defect.
            # Stop the leaked supervisor, then surface an EXPLICIT failure —
            # never launder a live co-bind into a passing assertion.
            Supervisor.stop(pid)
            exit({:second_bind_succeeded, second_sup})

          {:error, _} = e -> exit(e)
        end
      end)
      |> case do
        {pid, ref} ->
          receive do
            {:DOWN, ^ref, :process, ^pid, reason} -> unwrap_exit(reason)
          after
            2_000 -> flunk("second boot attempt hung")
          end
      end

    assert {:error, _reason} = result,
           "second Bandit over port #{ports.arm} must fail, got: #{inspect(result)}"

    assert reason_says_eaddrinuse?(elem(result, 1)),
           "expected an address-in-use failure, got: #{inspect(elem(result, 1))}"

    # No partially-started second tree left behind.
    refute Process.whereis(second_sup)

    # CRITICAL: the first substrate is untouched and still serving.
    assert {200, body} = http_get(ports.arm, "/subscriptions?api-version=2021-04-01")
    assert body =~ @default_sub
  end

  # --- helpers -------------------------------------------------------------

  # Stop the app, pin freshly probed ephemeral ports in app env, restart the
  # FULL tree. Retries with new ports when the probe-then-close race (or a
  # concurrent lane) steals a port before our bind lands.
  defp boot_with_retry(attempts \\ 12)

  defp boot_with_retry(0) do
    flunk("could not boot the smalt tree on a free ephemeral port after 12 attempts")
  end

  defp boot_with_retry(attempts) do
    if Process.whereis(Smalt.Supervisor), do: Application.stop(:smalt)

    Application.put_env(:smalt, :arm_port, probe_free_port())
    Application.put_env(:smalt, :egress_port, probe_free_port())
    Application.put_env(:smalt, :amqp_port, probe_free_port())
    Application.put_env(:smalt, :event_hubs_port, probe_free_port())

    case Application.ensure_all_started(:smalt) do
      {:ok, [_ | _]} ->
        :ok

      {:error, {app, reason}} ->
        send(self(), {:boot_retry, app, reason})
        Process.sleep(100)
        boot_with_retry(attempts - 1)
    end
  end

  # Probe-then-close ephemeral port (accept the TOCTOU bind race).
  defp probe_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp assert_process_whereis(name) do
    assert is_pid(Process.whereis(name)), "expected #{inspect(name)} to be registered"
  end

  # Real HTTP/1.1 over :gen_tcp — no Plug.Test, the request goes through the
  # actual Bandit listener socket.
  defp http_get(port, path) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)

    request =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Connection: close\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(sock, request)
    response = recv_all(sock, [])
    :gen_tcp.close(sock)

    [status_line | _] = String.split(response, "\r\n", parts: 2)
    <<"HTTP/1.1 ", status::binary>> = status_line
    code = status |> String.split(" ", parts: 2) |> hd() |> String.to_integer()
    body = response |> String.split("\r\n\r\n", parts: 2) |> Enum.at(1, "")
    {code, body}
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} -> recv_all(sock, [acc | [data]])
      {:error, :closed} -> IO.iodata_to_binary(acc)
      {:error, other} -> flunk("unexpected recv error: #{inspect(other)}")
    end
  end

  # SHIM-COURT: a clean exit (:normal) or a killed process is NOT an
  # address-in-use failure — laundering it into {:error, _} would make the
  # fail-closed assertion pass on a vacuous outcome. Flunk loudly instead.
  defp unwrap_exit(:normal),
    do: flunk("second Bandit boot exited :normal — bind did not fail (no eaddrinuse)")

  defp unwrap_exit(:killed),
    do: flunk("second Bandit boot process was killed — bind did not fail (no eaddrinuse)")

  defp unwrap_exit({:shutdown, reason}), do: {:error, reason}
  defp unwrap_exit(reason), do: {:error, reason}

  defp reason_says_eaddrinuse?(reason) do
    reason
    |> inspect(pretty: true, limit: 50)
    |> String.contains?("eaddrinuse")
  end
end
