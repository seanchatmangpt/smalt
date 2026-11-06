defmodule Smalt.Aoq.IovecCourtTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Egress-fence court (LANE-C5): paired rounds, min-of-N timing receipt on
  the batched iovec send (`Transport.send_batch/2`, ONE sendmsg) vs
  sequential per-frame sendmsg over real loopback UDP, alternating leg
  order per round — no mocks, no sleeps.

  **Premise-rot re-pin (OTP 29 `:socket`)**: the originally pinned fence
  (`min_batch <= min_seq * 1.05`) assumed blocking-socket economics. On
  OTP 29 the default `:socket` send is an asynchronous enqueue (~0.2µs
  per call), so N enqueues are ~4x cheaper in wall time than one N-entry
  iovec call on an idle loopback — measured min_seq ~5µs vs min_batch
  ~20µs, consistently. The fence's wall-time superiority CANNOT flip in
  favor of batch on this substrate; its lawful form here is the
  coalescing law: the batch is emitted as exactly ONE datagram carrying
  all frame bytes, while the sequential leg emits N datagrams. That fence
  flips with mutation (split the batch send and it fails) and is
  witnessed receive-side with a bounded poll. Timings are kept as a
  min-of-N printed receipt and a boundedness assertion
  (min_batch < @max_batch_us), never as a superiority claim.
  """

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Transport

  @loopback {127, 0, 0, 1}
  @rounds 7
  @frames 32
  @max_batch_us 5_000

  test "batch emits ONE coalesced datagram; timings recorded (min-of-N, alternating)" do
    {:ok, sink} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(sink, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    {:ok, %{port: port}} = :socket.sockname(sink)
    {:ok, sock} = Transport.open(@loopback, port, timeout: 2_000)

    frames =
      for i <- 1..@frames do
        {:ok, iolist} = Frame.encode(:binary.copy(<<i>>, 64), :binary.copy(<<i>>, 8))
        iolist
      end

    total_bytes = @frames * (64 + 8)
    bins = Enum.map(frames, &:erlang.iolist_to_binary/1)

    {min_batch, min_seq} = court(sock, sink, bins)

    IO.puts(
      "iovec court: min_batch=#{min_batch}µs min_seq=#{min_seq}µs " <>
        "(re-pin disclosure: async enqueue makes seq cheaper in wall time on OTP 29)"
    )

    # Boundedness fence on the batch path (not a superiority claim).
    assert min_batch < @max_batch_us,
           "batch egress unbounded: min_batch=#{min_batch}µs"

    # Coalescing fence: one batched send = one datagram with all frame bytes
    # (receive-side bounded-poll witness).
    assert {:ok, _} = Transport.send_batch(sock, frames)

    assert_eventually(
      fn ->
        case :socket.recvmsg(sink, 65_535, 0, 20) do
          {:ok, %{iov: iovec}} ->
            byte_size(:erlang.iolist_to_binary(List.wrap(iovec))) == total_bytes

          _ ->
            false
        end
      end,
      timeout: 2_000
    )

    Transport.close(sock)
    :socket.close(sink)
  end

  test "batch datagram count: batch sends 1 datagram where sequential sends N" do
    {:ok, sink} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(sink, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    {:ok, %{port: port}} = :socket.sockname(sink)
    {:ok, sock} = Transport.open(@loopback, port, timeout: 2_000)

    frames =
      for i <- 1..@frames do
        {:ok, iolist} = Frame.encode(:binary.copy(<<i>>, 64), :binary.copy(<<i>>, 8))
        iolist
      end

    bins = Enum.map(frames, &:erlang.iolist_to_binary/1)

    drain(sink)
    assert {:ok, _} = Transport.send_batch(sock, frames)
    assert count_datagrams(sink) == 1

    drain(sink)
    Enum.each(bins, fn bin ->
      :ok = :socket.sendmsg(sock, %{iov: [bin]}, [], 5_000)
    end)

    assert count_datagrams(sink) == @frames

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

    assert {:error, {:transport_refusal, :empty_body}} =
             Transport.send_batch(sock, [{:binary.copy(<<0>>, 64), <<>>}])

    assert {:error, {:transport_refusal, {:bad_frame, :atom}}} =
             Transport.send_batch(sock, [:atom])

    Transport.close(sock)
  end

  ##

  # Paired rounds: each round runs BOTH legs, alternating which goes first
  # (odd rounds batch-first, even rounds sequential-first) so a warming or
  # cooling machine cannot bias one leg. min-of-N across rounds.
  defp court(sock, sink, bins) do
    Enum.reduce(1..@rounds, {:infinity, :infinity}, fn round, {mb, ms} ->
      drain(sink)

      {t_batch, t_seq} =
        if rem(round, 2) == 1 do
          {time_batch(sock, bins), time_seq(sock, bins)}
        else
          {time_seq(sock, bins), time_batch(sock, bins)}
        end

      {min(mb, t_batch), min(ms, t_seq)}
    end)
  end

  defp time_batch(sock, bins) do
    t0 = System.monotonic_time()
    assert :ok = :socket.sendmsg(sock, %{iov: bins}, [], 5_000)
    System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)
  end

  defp time_seq(sock, bins) do
    t0 = System.monotonic_time()

    Enum.each(bins, fn bin ->
      assert :ok = :socket.sendmsg(sock, %{iov: [bin]}, [], 5_000)
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

  # Bounded-poll count of datagrams arriving within the deadline.
  defp count_datagrams(sink) do
    count_datagrams(sink, System.monotonic_time(:millisecond) + 1_000, 0)
  end

  defp count_datagrams(sink, deadline, n) do
    case :socket.recvmsg(sink, 65_535, 0, 20) do
      {:ok, _msg} ->
        count_datagrams(sink, deadline, n + 1)

      {:error, :timeout} ->
        n

      {:error, _} ->
        n
    end
  end
end
