defmodule Smalt.Posh.ClientTest do
  @moduledoc """
  POSH-002/005 lane F9: Chicago courts for `Smalt.Posh.Client` against the
  REAL posh binary (no acceptor doubles — the collaborator is the actual Go
  membrane booted through `Smalt.Posh.Port` on a temp UDS).

  Skipped loudly (never a faked pass) when the posh binary or the Go
  toolchain is absent; `POSH_REQUIRE_REAL=1` turns the skip into a failure
  (fail-closed gate, same pattern as the graphlaw wasm courts).
  """

  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually

  alias Smalt.Posh.Client
  alias Smalt.Posh.Port

  @posh_bin Path.expand("posh/bin/posh", __DIR__ <> "/../../..")
  @go_present not is_nil(System.find_executable("go"))
  @real_available File.regular?(@posh_bin) and @go_present

  @tag :real_posh
  test "loud skip pattern is non-vacuous: skip requires a genuinely absent binary or toolchain" do
    if @real_available do
      assert File.regular?(@posh_bin)
      assert System.find_executable("go")
    else
      assert not File.regular?(@posh_bin) or not @go_present
    end
  end

  describe "real posh membrane (UDS wire protocol v1)" do
    setup do
      if @real_available do
        dir = System.tmp_dir!()
        socket = Path.join(dir, "smalt-f9-#{System.unique_integer([:positive])}.sock")
        cfg = Path.join(dir, "smalt-f9-#{System.unique_integer([:positive])}.yaml")

        on_exit(fn ->
          File.rm(socket)
          File.rm(cfg)
        end)

        port_name = String.to_atom("posh_port_f9_#{System.unique_integer([:positive])}")
        client_name = String.to_atom("posh_client_f9_#{System.unique_integer([:positive])}")

        {:ok, _} =
          start_supervised(
            {Port, bin_path: @posh_bin, socket_path: socket, name: port_name},
            restart: :temporary
          )

        {:ok, _} =
          start_supervised(
            {Client, socket_path: socket, name: client_name},
            restart: :temporary
          )

        # Boot readiness is the real observable: the membrane socket exists
        # and the client has completed its first connect.
        assert_eventually(fn ->
          Port.status(port_name) == :up and Client.status(client_name) == :connected
        end, timeout: 5_000)

        {:ok, socket: socket, port: port_name, client: client_name}
      else
        message =
          "[SKIP] F9 real-posh courts: posh binary at #{@posh_bin} or the Go " <>
            "toolchain is absent (make -C posh build). A loud skip is not a pass. " <>
            "Set POSH_REQUIRE_REAL=1 to fail-closed."

        if System.get_env("POSH_REQUIRE_REAL") == "1", do: flunk(message)

        IO.puts(message)
        {:ok, skip: true}
      end
    end

    # Compile-time loud skip: an unavailable real collaborator tags every
    # court below.
    unless @real_available do
      @tag :skip
    end

    test "echo round-trips over the real membrane", %{client: client} do
      assert {:ok, %{"result" => %{"msg" => "hello"}}} =
               Client.request(client, "echo", %{"msg" => "hello"})
    end

    test "unknown op is a typed UPSTREAM error from the real registry", %{client: client} do
      assert {:error, {:upstream, %{code: "UPSTREAM", message: msg}}} =
               Client.request(client, "nope", %{})

      assert msg =~ "unknown op"
    end

    test "SIGKILL of the real posh pid is a typed TRANSPORT error, and the client recovers after a fresh membrane boots on the same socket", %{
      client: client,
      port: port,
      socket: socket
    } do
      assert {:ok, _} = Client.request(client, "echo", %{"n" => "1"})

      # Kill the real OS process: the port dies, the client's socket drops.
      {:ok, os_pid} = Port.os_pid(port)
      os_pid_str = to_string(os_pid)
      {_, 0} = System.cmd("kill", ["-9", os_pid_str])

      # The in-flight/next request fails typed transport — no raw exception.
      assert_eventually(
        fn ->
          assert {:error, {:transport, _}} = Client.request(client, "echo", %{"n" => "2"})
          true
        end,
        timeout: 5_000
      )

      # A fresh membrane on the SAME socket path: the client must reconnect
      # on its send_after backoff and resume serving requests.
      {:ok, _} =
        start_supervised(
          {Port, bin_path: @posh_bin, socket_path: socket},
          restart: :temporary
        )

      assert_eventually(
        fn ->
          match?({:ok, %{"result" => %{"n" => "3"}}}, Client.request(client, "echo", %{"n" => "3"}))
        end,
        timeout: 5_000
      )

      assert Process.alive?(GenServer.whereis(client))
    end
  end
end
