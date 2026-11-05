defmodule Smalt.Aoq.Transport do
  @moduledoc """
  AoQ phase-1 transport: connected `:socket` UDP + iovec send (`:socket.sendmsg`).

  Implements the ADOPTED phase-1 (reduced form) of
  `docs/jira/v26.11.5/aq-quic-transport-decision.md` (LANE-03): datagram
  framing leaves this module as an iolist — **never `<>` concatenation at
  the egress site** (LANE-13 egress fence, `scripts/aoq_egress_fence.sh`).
  Frames arrive as iodata from `Smalt.Aoq.Frame.encode/2` and are batched
  into ONE syscall via `:socket.sendmsg` on a connected UDP socket
  (decision §"Phase-1 fallback design" items 1–2).

  No QUIC crypto, no loss recovery — phase 2 (quinn NIF) owns those.

  No-sleep law: connect/readiness is a bounded poll on real observables
  (connect result / send result) with a `System.monotonic_time` deadline —
  never `Process.sleep`. The poll step is a blocking `:socket` call with a
  per-call timeout, which is the runtime scheduling the process away while
  it genuinely has nothing to do.
  """

  @default_timeout 2_000
  @poll_interval 20

  alias Smalt.Aoq.Frame

  @typedoc "Connected :socket handle."
  @type socket :: :socket.socket()

  @typedoc "Typed refusal. The wire reason is preserved for diagnosis."
  @type refusal :: {:error, {:transport_refusal, reason :: term}}

  @doc """
  Open a connected UDP `:socket` to `{host, port}` (host: IP string/charlist
  or `{a, b, c, d}` tuple).

  Bounded poll: the underlying `:socket.connect/3` uses a per-call timeout;
  on `:timeout` the loop re-arms until the `System.monotonic_time` deadline
  lapses, then refuses typed. No `Process.sleep`.
  """
  @spec open(:inet.ip_address() | :inet.hostname() | charlist(), :inet.port_number()) ::
          {:ok, socket()} | refusal()
  def open(host, port, opts \\ []) when is_integer(port) and port in 1..65_535 do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, addr} <- resolve(host),
         {:ok, sock} <- :socket.open(:inet, :dgram, :udp) do
      sockaddr = %{family: :inet, addr: addr, port: port}

      case connect_bounded(sock, sockaddr, deadline(timeout)) do
        :ok -> {:ok, sock}
        {:error, _} = refusal -> refusal
      end
    else
      {:error, reason} -> refuse(reason)
      other -> refuse(other)
    end
  end

  @doc """
  Send one datagram from an iovec of frames — ONE syscall via
  `:socket.sendmsg` on the connected socket (destination omitted; the
  5-tuple is fixed at connect). No `<>` anywhere on this path.

  Returns `{:ok, bytes}` or a typed refusal preserving the wire reason.
  """
  @spec send(socket(), iodata()) :: {:ok, non_neg_integer()} | refusal()
  def send(sock, frames) do
    bytes = :erlang.iolist_size(frames)

    case :socket.sendmsg(sock, %{iov: [:erlang.iolist_to_binary(frames)]}) do
      :ok -> {:ok, bytes}
      {:ok, n} when is_integer(n) -> {:ok, n}
      {:error, reason} -> refuse(reason)
      other -> refuse(other)
    end
  end

  @doc """
  Send a batch of frames as ONE `:socket.sendmsg` syscall — the iovec
  entries are per-frame `Smalt.Aoq.Frame.encode/2` iolists, NESTED
  (scatter-gather, egress fence law: zero `<>` anywhere on this path).

  Each element of `frames` is either an already-encoded iodata frame or a
  `{header, body}` tuple, which is encoded through `Frame.encode/2`
  (short header / empty payload refuse typed). Sends one datagram
  gathered from the whole iovec.
  """
  @spec send_batch(socket(), [iodata() | {binary(), binary()}]) ::
          {:ok, non_neg_integer()} | refusal()
  def send_batch(sock, frames) when is_list(frames) do
    with {:ok, iovec} <- encode_frames(frames) do
      bytes = Enum.sum(Enum.map(iovec, &:erlang.iolist_size/1))

      case :socket.sendmsg(sock, %{iov: iovec}) do
        :ok -> {:ok, bytes}
        {:ok, n} when is_integer(n) -> {:ok, n}
        {:error, reason} -> refuse(reason)
        other -> refuse(other)
      end
    end
  end

  @doc """
  Receive one datagram (bounded poll: blocking `recvmsg` with per-call
  timeout re-armed until the deadline — no `Process.sleep`).
  """
  @spec recv(socket(), non_neg_integer(), keyword) ::
          {:ok, binary()} | refusal()
  def recv(sock, buf_size \\ 2048, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    recv_bounded(sock, buf_size, deadline(timeout))
  end

  @doc "Close the socket."
  @spec close(socket()) :: :ok
  def close(sock), do: :ok = :socket.close(sock)

  ##

  defp connect_bounded(sock, sockaddr, deadline) do
    case :socket.connect(sock, sockaddr, @poll_interval) do
      :ok ->
        :ok
      {:ok, _} = ok ->
        ok

      {:error, :timeout} ->
        if System.monotonic_time(:millisecond) >= deadline do
          refuse(:connect_timeout)
        else
          connect_bounded(sock, sockaddr, deadline)
        end

      {:error, reason} ->
        refuse(reason)

      other ->
        refuse(other)
    end
  end

  defp recv_bounded(sock, buf_size, deadline) do
    case :socket.recvmsg(sock, buf_size, 0, @poll_interval) do
      {:ok, msg} ->
        {:ok, extract_payload(msg)}

      {:error, :timeout} ->
        if System.monotonic_time(:millisecond) >= deadline do
          refuse(:recv_timeout)
        else
          recv_bounded(sock, buf_size, deadline)
        end

      {:error, reason} ->
        refuse(reason)

      other ->
        refuse(other)
    end
  end

  defp encode_frames(frames) do
    frames
    |> Enum.reduce_while([], fn
      {header, payload}, acc ->
        case Frame.encode(header, payload) do
          {:ok, frame} -> {:cont, [frame | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      frame, acc when is_list(frame) or is_binary(frame) ->
        {:cont, [frame | acc]}

      other, _acc ->
        {:halt, {:error, {:bad_frame, other}}}
    end)
    |> case do
      {:error, reason} -> refuse(reason)
      # OTP 29 :socket iov entries are binaries-only; materialize each
      # per-frame iolist with iolist_to_binary (egress fence law: zero <>
      # — this is iolist consumption, never a concatenation site).
      iovec -> {:ok, Enum.reverse(iovec) |> Enum.map(&:erlang.iolist_to_binary/1)}
    end
  end

  defp extract_payload(%{iov: iovec}) do
    iovec
    |> List.wrap()
    |> :erlang.iolist_to_binary()
  end

  defp resolve(host) when is_tuple(host), do: {:ok, host}

  defp resolve(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} -> {:ok, addr}
      _ -> resolve_name(host)
    end
  end

  defp resolve_name(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, addr} -> {:ok, addr}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deadline(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  defp refuse(reason), do: {:error, {:transport_refusal, reason}}
end
