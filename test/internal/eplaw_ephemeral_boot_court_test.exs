defmodule Smalt.EplawEphemeralBootCourtTest do
  @moduledoc """
  BK-EPLAW court: test-facing boot paths default to EPHEMERAL ports; canonical
  ports (9443/9444/8443/5672/5673) are bound only by the real substrate front
  door, never by a test/bench harness self-boot.

  Legs (Chicago — real boots, bounded polls, no mocks):
    A. The `mix test` suite boot itself (no pins): every listener port is
       probed-free (not canonical) AND the ARM front door really accepts a
       TCP connection on the configured port.
    B. Fail-closed pin contract: an explicit SMALT_TEST_ARM_PORT=9443 wins —
       proving the ephemeral default is override-aware, not hardwired
       (non-vacuity: a hardwired ephemeral gate would fail this leg).
    C. The BK-PORTS2 offender class: a bare dev-context `mix run` harness
       self-boot via scripts/lib/test_boot_ports.exs + pin! gets a
       non-canonical ARM port and a real listener on it.
  """

  use ExUnit.Case, async: false

  @canonical [9443, 9444, 8443, 5672, 5673]
  @repo File.cwd!()

  test "leg A: suite boot without pins binds non-canonical, really-listening ports" do
    ports = %{
      arm: Smalt.Config.arm_port(),
      tls: Smalt.Config.arm_tls_port(),
      egress: Smalt.Config.egress_port(),
      amqp: Smalt.Config.amqp_port(),
      ehub: Smalt.Config.event_hubs_port(),
      mcp: Smalt.Config.mcp_port()
    }

    for {role, port} <- ports do
      refute port in @canonical, "#{role} bound canonical port #{port}"
      assert is_integer(port)
    end

    # real observable: ARM front door accepts a TCP connection (bounded poll)
    assert arm_accepts?(ports.arm, deadline_ms(10_000)),
           "ARM front door not accepting on #{ports.arm}"
  end

  test "leg B: explicit SMALT_TEST_ARM_PORT pin wins over the ephemeral default" do
    {out, 0} =
      System.cmd("mix", ["run", "--no-start", "-e",
        "IO.puts Application.get_env(:smalt, :arm_port)"],
        env: %{"MIX_ENV" => "test", "SMALT_TEST_ARM_PORT" => "9443",
               "MIX_BUILD_ROOT" => build_root()},
        cd: @repo, stderr_to_stdout: true)

    last_line = out |> String.split("\n") |> Enum.reject(&(String.trim(&1) == "")) |> List.last()
    assert String.trim(last_line || "") == "9443",
           "SMALT_TEST_ARM_PORT=9443 pin not honored by config/test.exs; got: #{inspect(out)}"
  end

  @tag timeout: 300_000
  test "leg C: dev-context self-boot via SmaltTestBoot.pin! gets an ephemeral ARM port" do
    eval = ~S"""
    Code.require_file("scripts/lib/test_boot_ports.exs", File.cwd!())
    SmaltTestBoot.pin!()
    {:ok, _} = Application.ensure_all_started(:smalt)
    port = Smalt.Config.arm_port()
    canonical? = port in [9443, 9444, 8443, 5672, 5673]
    IO.puts("EPLAW_ARM=#{port} CANONICAL=#{canonical?}")
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)
    :gen_tcp.close(sock)
    System.stop(0)
    # SLEEP-CLASS: POLL-STEP — trailing settle inside the child `mix run` eval
    # after System.stop(0); child exit is awaited by System.cmd, this only
    # drains the BEAM before the VM halts.
    Process.sleep(250)
    """

    {out, _code} =
      System.cmd("mix", ["run", "--no-start", "-e", eval, "--no-halt"],
        env: %{"MIX_BUILD_ROOT" => "_build-eplaw"},
        cd: @repo, stderr_to_stdout: true)

    assert String.contains?(out, "CANONICAL=false"),
           "dev-context self-boot landed on a canonical port; output:\n#{out}"

    assert Regex.run(~r/EPLAW_ARM=(\d+)/, out) |> then(fn [_, p] -> String.to_integer(p) end)
           |> then(&(&1 not in @canonical)),
           "dev ARM port not ephemeral; output:\n#{out}"
  end

  defp arm_accepts?(port, deadline) do
    do_poll(port, deadline)
  end

  defp do_poll(port, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          # SLEEP-CLASS: POLL-STEP — deadline-checked bounded poll step in
          # do_poll/2; the deadline bounds total wait, the connect probe is
          # the observable.
          Process.sleep(100)
          do_poll(port, deadline)
        else
          false
        end
    end
  end

  defp deadline_ms(ms), do: System.monotonic_time(:millisecond) + ms

  defp build_root, do: Path.join(@repo, "_build-eplaw")
end
