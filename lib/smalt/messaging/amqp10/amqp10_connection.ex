defmodule Smalt.Amqp10.Connection do
  @moduledoc """
  Root actor of the crash-only AMQP 1.0 router family
  (`lib/smalt/messaging/amqp10/` — parallel to, and never touching,
  `lib/smalt/messaging/amqp/`).

  Crash-only laws:

    * The connection is the ROOT: it traps exits. Sessions and links are
      `spawn_link`ed and never trap — any child 'EXIT' reaches the root,
      which exits immediately with the same reason (crash cascade), and any
      root death kills every session and link through the unbroken link tree.
    * First bytes must be the exact AMQP 1.0 protocol header
      ("AMQP\\x00\\x01\\x00\\x00"); anything else is a typed exit
      `{:bad_protocol_header, got}`.
    * Transport death (tcp_closed/tcp_error, including client RST) exits the
      root, cascading through the whole tree.
    * Sockets are owned by `:gen_tcp.controlling_process/2`; frames are
      decoded by `Smalt.Amqp10.FrameDecoder` and incomplete frames are kept
      as a buffer in the connection state ({:more, buffer}).
    * Sessions spawn lazily, one per channel, on the first frame seen for it.
    * Settled transfers land in the named ETS table `:amqp10_settled`.
    * Every actor class is labeled via `:proc_lib.set_label/1` (OTP-29 lane).
  """

  use GenServer

  @protocol_header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>
  @ets_table :amqp10_settled

  # -- listener / supervision surface ---------------------------------------

  @doc """
  Starts a TCP listener on `port` (0 = ephemeral). Each accepted socket gets
  a linked connection process; `opts[:notify]` receives
  `{:amqp10_connection, conn_pid}` per accept. Returns {:ok, listener_pid,
  port}.
  """
  @spec start_listener(:inet.port_number(), keyword()) ::
          {:ok, pid(), :inet.port_number()} | {:error, term()}
  def start_listener(port, opts \\ []) do
    with {:ok, lsock} <- :gen_tcp.listen(port, [:binary, packet: :raw, active: false,
                                                 nodelay: true, reuseaddr: true,
                                                 backlog: 32]) do
      {:ok, port} = :inet.port(lsock)
      parent = self()

      pid = spawn_link(fn -> :proc_lib.set_label({__MODULE__, :listener, port})
                            accept_loop(lsock, opts, parent) end)

      receive do
        {:amqp10_listener_ready, ^pid} -> :ok
      after
        5_000 -> :ok
      end

      {:ok, pid, port}
    end
  end

  defp accept_loop(lsock, opts, parent) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        {:ok, pid} =
          GenServer.start(__MODULE__, %{socket: :pending, opts: opts, parent: parent})

        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, {:amqp10_socket, sock})
        if is_pid(opts[:notify]), do: send(opts[:notify], {:amqp10_connection, pid})
        accept_loop(lsock, opts, parent)

      {:error, _closed} ->
        :ok
    end
  end

  # -- gen_server callbacks --------------------------------------------------

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    :proc_lib.set_label({__MODULE__, :connection})
    {:ok,
     Map.merge(%{channels: %{}, buffer: <<>>, header_seen?: false, socket: nil}, state)}
  end

  @impl true
  def handle_info({:amqp10_socket, sock}, state) do
    :inet.setopts(sock, active: true)
    {:noreply, %{state | socket: sock}}
  end

  def handle_info({:tcp, _sock, data}, state) do
    case on_bytes(data, state) do
      {:ok, state2} -> {:noreply, state2}
      {:exit, reason} -> {:stop, reason, state}
    end
  end

  # Outbound frames from sessions/links are funneled through the root (it
  # owns the socket). tx/3 raises on socket death (:gen_tcp.send exits) —
  # transport death cascades via the supervisor, never via a return value.
  def handle_info({:amqp10_tx, channel, performative}, state) do
    :ok = tx(state, channel, performative)
    {:noreply, state}
  end

  def handle_info({:tcp_error, _sock, reason}, state),
    do: {:stop, {:transport_closed, reason}, state}

  def handle_info({:tcp_closed, _sock}, state),
    do: {:stop, {:transport_closed, :tcp_closed}, state}

  # Crash cascade law: ANY child 'EXIT' at the root -> immediate exit.
  def handle_info({:EXIT, child, reason}, state) do
    {:stop, {:child_crash, child, reason}, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- frame pump -------------------------------------------------------------

  defp on_bytes(data, state) do
    buffer = state.buffer <> data

    if state.header_seen? do
      pump_frames(buffer, state)
    else
      case buffer do
        <<>> ->
          {:ok, state}

        _ ->
          n = byte_size(buffer)

          cond do
            n >= 8 ->
              <<got::binary-size(8), rest::binary>> = buffer

              if got == @protocol_header do
                pump_frames(rest, %{state | header_seen?: true, buffer: <<>>})
              else
                {:exit, {:bad_protocol_header, got}}
              end

            # Partial header: only survivable while it is still a prefix of
            # the real thing.
            true ->
              if binary_slice(@protocol_header, 0, n) == buffer do
                {:ok, %{state | buffer: buffer}}
              else
                {:exit, {:bad_protocol_header, buffer}}
              end
          end
        end
    end
  end

  defp pump_frames(<<>>, state), do: {:ok, %{state | buffer: <<>>}}

  defp pump_frames(buffer, state) do
    case Smalt.Amqp10.FrameDecoder.decode_frame(buffer) do
      {:ok, frame, rest} ->
        case route(frame, state) do
          {:ok, state2} -> pump_frames(rest, state2)
          {:stop, reason} -> {:exit, reason}
        end

      {:more, _buf} ->
        {:ok, %{state | buffer: buffer}}

      {:error, reason} ->
        {:exit, {:bad_frame, reason}}
    end
  end

  defp route(frame, state) do
    {perf, _fields} = frame.performative
    channel = frame.channel

    cond do
      perf == :open ->
        tx(state, 0, {:open, %{container_id: "smalt-amqp10",
                               max_frame_size: Smalt.Amqp10.FrameDecoder.max_frame_size(),
                               channel_max: 65_535, idle_time_out: 60_000}})
        {:ok, state}

      perf == :close ->
        tx(state, 0, {:close, %{}})
        {:stop, :normal}

      perf == :heartbeat ->
        {:ok, state}

      true ->
        case Map.fetch(state.channels, channel) do
          {:ok, pid} ->
            send(pid, {:amqp10_frame, frame.performative, frame.payload})
            {:ok, state}

          :error ->
            pid = Smalt.Amqp10.Session.start_link(
              channel: channel,
              conn: self(),
              table: ets_table()
            )

            receive do
              {:amqp10_session_ready, ^pid} -> :ok
            after
              5_000 -> exit(:session_start_timeout)
            end

            send(pid, {:amqp10_frame, frame.performative, frame.payload})
            {:ok, %{state | channels: Map.put(state.channels, channel, pid)}}
        end
    end
  end

  defp tx(state, channel, performative) do
    frame = Smalt.Amqp.FrameCodec.encode_frame(:amqp, channel, performative)

    case :gen_tcp.send(state.socket, frame) do
      :ok -> :ok
      {:error, reason} -> exit({:tcp_tx_error, reason})
    end
  end

  # The settled ledger must outlive any single connection (courts read it
  # after cascades), so it is owned by `Smalt.Amqp10.Ledger`: a named,
  # connection-independent GenServer created with `heir: :init` so its death
  # transfers the table (contents intact) to `:init` instead of deleting it.
  # Connection crashes never propagate to it (`ensure/0` is unlinked). See
  # `amqp10_ledger.ex` and receipt bk41-amqp10-ledger-owner.md.
  defp ets_table do
    :ok = Smalt.Amqp10.Ledger.ensure()
    @ets_table
  end
end
