defmodule Smalt.Aoq.IovecCourtTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Egress-fence court (LANE-C5): paired rounds, min-of-N — batched iovec
  send (`Transport.send_batch/2`, ONE sendmsg) vs sequential per-frame
  sendmsg over real loopback UDP, alternating leg order per round. Fence:
  `min_batch <= min_seq * 1.05`. Receive side is a bounded poll on real
  datagrams — no mocks, no sleeps.
  """

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Transport

  @loopback {127, 0, 0, 1}
  @rounds 7
  @frames 32

  test "batched iovec egress is not slower than sequential sends (min-of-N, alternating order)" do
    {:ok, sink} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(sink, {:socket.sockaddr_in, {127, 0, 0, 1}, 0})
    {:ok, {:socket.sockaddr_in, _, port}} = :socket.sockname(sink)
    {:ok, sock} = Transport.open(@loopback, port, timeout: 2_000)

    frames =
      for i <- 1..@frames do
        {:ok, iolist} = Frame.encode(:binary.copy(<<i>>, 64), :binary.copy(<<i>>, 8))
        iolist
      end

    total_bytes = @frames * (64 + 8)

    {min_batch, min_seq} = court(sock, sink, frames)

    assert min_batch <= min_seq * 1.05,
           "egress fence violated: min_batch=#{min_batch}µs vs min_seq=#{min_seq}µs"

    # One batched send emits the full iovec as one datagram (bounded-poll
    # receive witness on the real receive side).
    assert {:ok, _} = Transport.send_batch(sock, frames)

    assert_eventually(
      fn ->
        case :socket.recvmsg(sink, 65_535, 0, 20) do
          {:ok, %{iovec: iovec}} ->
            byte_size(:erlang.iolist_to_binary(List.wrap(iovec))) == total_bytes

          _ ->
            false
        end
      end,
      timeout:  2_000
    )

    Transport.close(sock)
    :socket.close(sink)
  end

  test "send_batch on a closed socket is a typed refusal, never a crash" do
    {:ok, sock} = Transport.open(@loopback, 53_539)
    Transport.close(sock)

    header = :binary.copy(<<2>>, 64)

    assert {:error, {:transport_refusal, reason}} =
             Transport.send_batch(sock, [header, <<"x">>])

    assert reason != nil
  end

  test "send_batch refuses malformed frames typed" do
    {:ok, sock} = Transport.open(@loopback, 53_539)

    assert {:error, {:transport_refusal, :short_header}} =
             Transport.send_batch(sock, [{"short", <<"x">>}])

    assert {:error, {:transport_refusal, :empty_payload}} =
             Transport.send_batch(sock, [{:binary.copy(<<0>>, 64), <<>>}])

    assert {:error, {:transport_refusal, {:bad_frame, :atom}}} =
             Transport.send_batch(sock, [:atom])

    Transport.close(sock)
  end

  ##

  # Paired rounds: each round runs BOTH legs, alternating which goes first
  # (odd rounds batch-first, even rounds sequential-first) so a warming or
  # cooling machine cannot bias one leg. min-of-N across rounds.
  defp court(sock, sink, frames) do
    Enum.reduce(1..@rounds, {:infinity, :infinity}, fn round, {mb, ms} ->
      drain(sink)

      {t_batch, t_seq} =
        if rem(round, 2) == 1 do
          {time_batch(sock, frames), time_seq(sock, frames)}
        else
          {time_seq(sock, frames), time_batch(sock, frames)}
        end

      {min(mb, t_batch), min(ms, t_seq)}
    end)
  end

  defp time_batch(sock, frames) do
    t0 = System.monotonic_time()
    assert {:ok, _} = Transport.send_batch(sock, frames)
    System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)
  end

  defp time_seq(sock, frames) do
    t0 = System.monotonic_time()

    Enum.each(frames, fn frame ->
      {:ok, _} = :socket.sendmsg(sock, %{iovec: [frame]})
    end)

    System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)
  end

  # Bounded-poll drain of the sink's receive buffer between legs — the
  # loopback buffer must be empty so neither leg inherits queued work.
  defp drain(sink) do
    drain_loop(sink, System.monotonic_time(:millisecond) + 2_000)
  end

  defp drain_loop(sink, deadline) do
    case :socket.recvmsg(sink, 65_535, 0, 20) do
      {:ok, _msg} ->
        if System.monotonic_time(:millisecond) >= deadline do
          :ok
        else
          drain_loop(sink, deadline)
        end

      {:error, :timeout} ->
        :ok

      {:error, _} ->
        :ok
    end
  end
end
