defmodule Smalt.Messaging.Kafka.Listener do
  @moduledoc """
  AZ-1 — Kafka wire listener on :9092 (`config :smalt, :kafka_port`).

  TCP accept loop mirroring `Smalt.Amqp.Listener`: exponential accept
  backoff, port 0 = ephemeral (bound port read via `port/1`), accepted
  sockets handed to `Smalt.Messaging.Kafka.Conn` under a dedicated
  DynamicSupervisor (`Smalt.Messaging.Kafka.ConnSup`) so a connection crash
  never reaches the listener.
  """

  use GenServer
  require Logger

  alias Smalt.Messaging.Kafka.Conn

  @accept_timeout_ms 200
  @base_backoff_ms 50
  @max_backoff_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The actual bound port (port 0 binds ephemeral)."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    Process.set_label(%{service: :kafka, role: :listener})

    port = Keyword.get(opts, :port) || Application.get_env(:smalt, :kafka_port, 9092)

    case :gen_tcp.listen(port, [
           :binary,
           packet: :raw,
           active: false,
           reuseaddr: true,
           ip: {127, 0, 0, 1},
           backlog: 128
         ]) do
      {:ok, lsock} ->
        {:ok, bound} = :inet.port(lsock)
        Logger.info("[kafka] listener bound on port #{bound}")

        Process.send_after(self(), :accept, 0)
        {:ok, %{lsock: lsock, port: bound, attempts: 0}}

      {:error, reason} ->
        {:stop, {:listen_failed, port, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.lsock, @accept_timeout_ms) do
      {:ok, socket} ->
        spawn_conn(socket, state)
        Process.send_after(self(), :accept, 0)
        {:noreply, state}

      {:error, :timeout} ->
        Process.send_after(self(), :accept, 0)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, %{state | lsock: nil}}

      {:error, reason} ->
        attempts = state.attempts + 1

        Logger.warning("[kafka] accept error #{inspect(reason)} (attempt #{attempts})")

        Process.send_after(self(), :accept, min(@base_backoff_ms * 2 ** (attempts - 1), @max_backoff_ms))

        {:noreply, %{state | attempts: attempts}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp spawn_conn(socket, state) do
    sup = Smalt.Messaging.Kafka.ConnSup

    if Process.whereis(sup) do
      child = %{
        id: {:kafka_conn, make_ref()},
        start:
          {Conn, :start_link,
           [[socket: socket, advertised_port: state.port]]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(sup, child) do
        {:ok, _pid} -> :ok

        {:error, reason} ->
          :gen_tcp.close(socket)

          Logger.warning("[kafka] conn start failed: #{inspect(reason)}")
      end
    else
      :gen_tcp.close(socket)
      Logger.warning("[kafka] ConnSup not running; dropping accepted socket")
    end

    :ok
  end
end
