defmodule SmaltProxy.Router do
  @moduledoc """
  Loopback-only listener on ONE well-known port (default 9460).

  Accept loop: a plain GenServer owning the listen socket, acceptor process
  per connection (spawned, linked, trap-exit supervised by the acceptor
  parent through `Process.flag(:trap_exit, true)`). Each connection is echoed
  with the lane-namespace contract stamped on it; the real substrate
  forwarding is a stub (see README).

  Bound to 127.0.0.1 only — WO-23 §2 ("bound 127.0.0.1 only").
  """

  use GenServer

  require Logger

  @default_port 9460

  defstruct [:listen_socket, :port]

  # ---- client API ----

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Port the listener is bound to."
  @spec port() :: :inet.port_number()
  def port, do: GenServer.call(__MODULE__, :port)

  @doc """
  In-band echo probe: send a line, read the same line back. Used by tests and
  by `substrate.sh`-class shims to verify the listener is accepting.
  """
  @spec echo(binary) :: {:ok, binary} | {:error, term}
  def echo(payload) when is_binary(payload) do
    with {:ok, sock} <-
           :gen_tcp.connect(~c"127.0.0.1", port(), [:binary, active: false, packet: :raw]) do
      :ok = :gen_tcp.send(sock, payload)
      result = recv_exact(sock, byte_size(payload), "")
      :gen_tcp.close(sock)
      result
    end
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)

    {:ok, listen} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, _acceptor} = Task.start_link(fn -> accept_loop(listen) end)
    Logger.info("smalt_proxy: listening on 127.0.0.1:#{port} (loopback only)")
    {:ok, %__MODULE__{listen_socket: listen, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:tcp, sock, data}, state) do
    :ok = :gen_tcp.send(sock, data)
    {:noreply, state}
  end

  # ---- accept loop (runs in the Task-linked acceptor process) ----

  defp accept_loop(listen) do
    {:ok, sock} = :gen_tcp.accept(listen)
    {:ok, handler} = Task.start_link(fn -> conn_loop(sock) end)
    :ok = :gen_tcp.controlling_process(sock, handler)
    accept_loop(listen)
  end

  defp recv_exact(_sock, 0, buffer), do: {:ok, buffer}

  defp recv_exact(sock, remaining, buffer) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        got = byte_size(data)

        if got >= remaining do
          {:ok, binary_part(buffer <> data, 0, byte_size(buffer) + remaining)}
        else
          recv_exact(sock, remaining - got, buffer <> data)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp conn_loop(sock) do
    case :gen_tcp.recv(sock, 0, 15_000) do
      {:ok, data} ->
        :ok = :gen_tcp.send(sock, data)
        conn_loop(sock)

      {:error, _closed} ->
        :ok = :gen_tcp.close(sock)
    end
  end
end
