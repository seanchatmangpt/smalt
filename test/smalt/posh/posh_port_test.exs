defmodule Smalt.Posh.PoshPortTest do
  @moduledoc """
  POSH-005 phase-change court: the posh Go binary boots as a BEAM port, the
  UDS socket appears, a real `Smalt.Posh.Client` request round-trips, and a
  stop makes the socket vanish. State-flip observables only — no sleeps.
  """

  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually

  alias Smalt.Posh.{Client, Port}

  @bin_path Path.join(__DIR__, "../../../posh/bin/posh") |> Path.expand()

  # Loud typed skip — a missing binary is never a faked pass (build it with
  # `make -C posh build`; `just posh-build` wraps the same make target).
  if File.exists?(@bin_path) do
    @tag :posh_port
  else
    @tag skip: "[POSH-PORT-SKIP] #{@bin_path} missing — run `make -C posh build`"
  end

  test "port boots the real binary, socket appears, echo round-trips, stop removes socket" do
    socket = "/tmp/smalt-p1-#{System.unique_integer([:positive])}.sock"
    on_exit(fn -> File.rm(socket) end)

    name = String.to_atom("posh_port_" <> Integer.to_string(System.unique_integer([:positive])))

    assert {:ok, pid} = Port.start_link(socket_path: socket, bin_path: @bin_path, name: name)
    ref = Process.monitor(pid)

    # State flip #1: socket appears (bounded poll on the real observable).
    assert_eventually(fn -> File.exists?(socket) end, timeout: 5_000)
    assert :up == Port.status(name)

    assert {:ok, os_pid} = Port.os_pid(name)
    # OTP 29 returns the os pid as an integer (docs say charlist; both
    # to_string-coercible).
    assert pid_str = os_pid |> to_string()
    assert pid_str != ""

    # The os process named by that pid is really alive (kill -0 receipts).
    {_, exit_code} = System.cmd("kill", ["-0", pid_str])
    assert exit_code == 0

    # Wire proof: a real client echoes through the binary over the UDS.
    client_name =
      String.to_atom("posh_client_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, _} = Client.start_link(socket_path: socket, name: client_name)

    assert_eventually(fn -> Client.status(client_name) == :connected end, timeout: 5_000)

    assert {:ok, %{"result" => %{"msg" => "posh-port-court"}}} =
             Client.request(client_name, "echo", %{msg: "posh-port-court"})

    # State flip #2: stop → socket gone, os process gone.
    assert :ok = Port.stop(name)

    assert_eventually(
      fn -> not File.exists?(socket) end,
      timeout: 5_000
    )

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    refute File.exists?(socket)

    # The OS process itself is really dead — socket absence alone could be
    # a stale-file artifact. kill -0 must fail once the pid is gone.
    assert_eventually(
      fn ->
        {_, code} = System.cmd("kill", ["-0", pid_str])
        code != 0
      end,
      timeout: 5_000
    )
  end

  test "boot failure is typed: a missing binary yields {:error, {:port, {:enoent, _}}}" do
    # A missing binary — the wrapper must surface a typed {:port, _}
    # refusal, never hang and never raise raw.
    socket = "/tmp/smalt-p1-#{System.unique_integer([:positive])}.sock"

    assert {:error, {:port, {:enoent, _}}} =
             Port.start_link(
               socket_path: socket,
               bin_path:
                 Path.join(System.tmp_dir!(), "smalt-p1-not-a-bin-#{System.unique_integer([:positive])}"),
               name: String.to_atom("posh_port_" <> Integer.to_string(System.unique_integer([:positive])))
             )
  end
end
