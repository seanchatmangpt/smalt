defmodule Smalt.Internal.BkamqpfF2aBoundaryCourtTest do
  @moduledoc """
  Lane BK-AMQPF, finding F2a: a malformed frame body must exit the AMQP10
  connection process TYPED (`{:bad_frame, reason}`), never as an untyped
  raise (bare MatchError / FunctionClauseError) escaping the decode/commit
  path. `FrameDecoder` is typed end-to-end (wire-exp4 8-leg + skepr1/skepr2
  repairs); this court proves the residual at the PROCESS boundary — real
  TCP, real connection process, real crash, no mocks, no sleeps.

  Falsifier: any leg where the connection exits with a raw exception struct
  (or stays alive on hostile input) is a failure.
  """

  use ExUnit.Case, async: false

  alias Smalt.Amqp10.Connection

  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>

  # 8-byte AMQP frame header + body; doff=2, type 0 (amqp), channel 0.
  defp frame(body) do
    size = 8 + byte_size(body)
    <<size::32, 2::8, 0::8, 0::16, body::binary>>
  end

  # Hostile body riding in first positional field of a described performative
  # (attach, 0x12) — same corpus shape as the wire_exp4 decoder court.
  defp hostile_body(element), do: <<0x00, 0x53, 0x12, element::binary>>

  @truncated_classes [
    {:bin8, <<0xA0, 200, "abc">>, :truncated_frame},
    {:str8, <<0xA1, 200, "abc">>, :truncated_frame},
    {:sym8, <<0xA3, 200, "abc">>, :truncated_frame},
    {:bin32, <<0xB0, 200::32, "abc">>, :truncated_frame},
    {:str32, <<0xB1, 200::32, "abc">>, :truncated_frame},
    {:sym32, <<0xB3, 200::32, "abc">>, :truncated_frame},
    {:uuid, <<0x98, "short">>, :truncated_frame},
    # 0xC0 trailing byte inside the declared slice -> :bad_element class
    {:list_trailing, <<0xC0, 4, 1, 0x50, 9, 0xFF>>, :bad_element},
    # odd element count in a map (BK-SKEP F1 class) -> :bad_element class
    {:map_odd_count, <<0xC1, 2, 1, 0x40>>, :bad_element}
  ]

  test "corrupt-frame corpus exits the connection process TYPED, never untyped" do
    for {label, element, expected_reason} <- @truncated_classes do
      {:ok, lpid, port} = Connection.start_listener(0, notify: self())
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

      conn =
        receive do
          {:amqp10_connection, pid} -> pid
        after
          5_000 -> flunk("no connection notify")
        end

      ref = Process.monitor(conn)
      :ok = :gen_tcp.send(sock, @header)
      :ok = :gen_tcp.send(sock, frame(hostile_body(element)))

      reason =
        receive do
          {:DOWN, ^ref, :process, ^conn, reason} -> reason
        after
          10_000 -> flunk("connection survived hostile frame #{inspect(label)}")
        end

      assert reason == {:bad_frame, expected_reason},
             "leg #{inspect(label)} exited #{inspect(reason)}, " <>
               "expected typed {:bad_frame, #{inspect(expected_reason)}}"

      :ok = :gen_tcp.close(sock)
    end
  end

  test "EXPL-4 F2 witness frame exits typed at the process boundary" do
    # The exact witnessed pre-repair shape: declared 200-byte str8, 3 bytes follow.
    {:ok, lpid, port} = Connection.start_listener(0, notify: self())
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    conn =
      receive do
        {:amqp10_connection, pid} -> pid
      after
        5_000 -> flunk("no connection notify")
      end

    ref = Process.monitor(conn)
    :ok = :gen_tcp.send(sock, @header)
    :ok = :gen_tcp.send(sock, frame(<<0x00, 0x53, 0x12, 0xA1, 200, "abc">>))

    assert_receive {:DOWN, ^ref, :process, ^conn, {:bad_frame, :truncated_frame}}, 10_000

    :ok = :gen_tcp.close(sock)
  end

  test "non-vacuity: a well-formed frame keeps the connection alive and answered" do
    {:ok, lpid, port} = Connection.start_listener(0, notify: self())
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    conn =
      receive do
        {:amqp10_connection, pid} -> pid
      after
        5_000 -> flunk("no connection notify")
      end

    ref = Process.monitor(conn)
    :ok = :gen_tcp.send(sock, @header)

    open =
      IO.iodata_to_binary(
        Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:open, %{container_id: "bkamqpf-court"}})
      )

    :ok = :gen_tcp.send(sock, open)

    # Connection must answer a typed :open reply and NOT die.
    assert {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
    assert {:ok, %{}, _rest} = Smalt.Amqp10.FrameDecoder.decode_frame(data)
    refute_receive {:DOWN, ^ref, :process, ^conn, _}, 500

    :ok = :gen_tcp.close(sock)
  end
end
