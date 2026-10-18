defmodule Smalt.Wire.AmqpWireTest do
  @moduledoc """
  T2 wire tier — AMQP port behavior as it exists today.

  Boots Smalt.AmqpBroker (when compiled) on an ephemeral port from the pinned
  Application env contract (Application.get_env(:smalt, :amqp_port, 5672)),
  connects over a raw :gen_tcp socket, sends the AMQP 1.0 protocol header
  "AMQP\\x00\\x01\\x00\\x00", and asserts the broker responds with SOME valid
  AMQP protocol-header frame (starts with the 8-byte "AMQP\\x00\\x01\\x00\\x00")
  within 5 seconds.

  This documents the wire tier honestly as it exists: the broker is not yet a
  full AMQP 1.0 open-begin-transfer peer, so the assertion is header-level
  only. Do not weaken this test; it is strengthened at integration when the
  broker completes open/begin/attach flows.
  """

  use ExUnit.Case, async: false

  @amqp_header "AMQP\x00\x01\x00\x00"
  @sasl_header "AMQP\x03\x01\x00\x00"
  @recv_timeout 5000

  setup context do
    port = SmaltTest.PortEnv.free_port()

    SmaltTest.Lifecycle.stop_shared_tree_with_children()

    # save-prev/on_exit-restore discipline (test-isolation-leak gate), via the
    # canonical nil-preserving helper (v26.10.18 e2e-wire D1/D4).
    prev = SmaltTest.PortEnv.snapshot([:arm_port, :egress_port, :amqp_port, :event_hubs_port])

    # The broker tree also binds the Event Hubs listener on :event_hubs_port;
    # keep it off the default 5673 so concurrent runs never clash.
    SmaltTest.PortEnv.apply(
      arm_port: SmaltTest.PortEnv.free_port(),
      egress_port: SmaltTest.PortEnv.free_port(),
      amqp_port: port,
      event_hubs_port: SmaltTest.PortEnv.free_port()
    )

    broker_available? = Code.ensure_loaded?(Smalt.AmqpBroker)

    if broker_available? do
      {:ok, sup} =
        Supervisor.start_link(
          [Smalt.Store, {Smalt.AmqpBroker, []}],
          strategy: :one_for_one,
          name: Smalt.WireSup
        )

      on_exit(fn ->
        stop_tree(sup)
        SmaltTest.Lifecycle.restore_app()
        SmaltTest.Lifecycle.ensure_store_up()

        # AZB-11b: the env snapshot must win — restore_app/0 re-writes the
        # shifted port envs, so the saved prev values are applied AFTER it.
        SmaltTest.PortEnv.restore(prev)
      end)
    end

    {:ok, amqp: port, broker_available: broker_available?}
  end

  @tag :wire
  test "broker answers the AMQP 1.0 protocol header with a valid header frame", %{
    amqp: port,
    broker_available: broker_available?
  } do
    # Honest gate: the broker module must be compiled (it lives in lib/).
    # No silent skip — if it is missing, this test fails loudly.
    assert broker_available?, "Smalt.AmqpBroker is not compiled"

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5000)

    # The broker's connection state machine expects the plain AMQP 1.0 header
    # ("AMQP\x00\x01\x00\x00") even for its SASL layer exchange, and replies
    # with its own protocol header + sasl-mechanisms frame.
    :ok = :gen_tcp.send(sock, @amqp_header)

    {:ok, reply} = recv_frame(sock, @recv_timeout)

    :gen_tcp.close(sock)

    # The reply must carry a valid AMQP protocol header: 8 bytes, "AMQP" id +
    # major/minor/revision. This documents the wire tier as it exists today;
    # do not weaken — strengthen at integration (open/begin/attach flows).
    assert byte_size(reply) >= 8
    assert :binary.part(reply, 0, 4) == "AMQP"
    assert :binary.part(reply, 0, 8) == @amqp_header
  end

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  # Teardown resilience: the broker tree does not always stop cleanly on
  # Supervisor.stop; fall back to a hard kill. Teardown only — assertions
  # are never softened.
  defp stop_tree(sup) do
    try do
      Supervisor.stop(sup, :normal, 5000)
    catch
      _, _ -> Process.exit(sup, :kill)
    end
  end

  defp recv_frame(sock, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

end
