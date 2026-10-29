defmodule Smalt.Amqp.Listener do
  @moduledoc """
  TCP accept loop for the AMQP 1.0 broker.

  One listener GenServer per transport lane: `{:sb, port}` for Service Bus (5672) and
  `{:eh, port}` for Event Hubs (5673). Accepted sockets are handed to
  `Smalt.Amqp.Connection.start_link(socket, mode: :sb | :eh)` under the broker's
  `DynamicSupervisor` (`Smalt.AmqpBroker.ConnSup`), so a connection crash never
  reaches the listener.

  Guarantees:
  - accept errors retry with exponential backoff (50 ms doubling, 5 s cap) — the
    listener never crashes the supervisor;
  - a failed `Smalt.Amqp.Connection` start (module absent, supervisor down, child
    crash-on-start) closes the socket, logs once, and keeps accepting;
  - `port 0` binds an ephemeral port; the bound port is read via `port/1`;
  - the connection fan-in is CAPPED (`Smalt.Amqp.Listener.max_connections/0`,
    `config :smalt, :amqp_max_connections`, default 10_000 per lane): an
    accepted socket beyond the cap is closed (typed refusal) and a
    `[:smalt, :amqp, :connection_refused]` telemetry counter event is emitted;
    the listener keeps accepting and never crashes (SCVD backpressure MED-4).

  Start signatures:
  - `start_link({name, port})`
  - `start_link({name, port, opts})` with `opts`: `[:name]` (registered name override,
    used so the two lanes get distinct supervisor child ids and process names) and
    `[:conn_sup]` (DynamicSupervisor ref override for tests; `nil` disables
    connection spawning entirely).
  """

  use GenServer
  require Logger

  @accept_timeout_ms 200
  @base_backoff_ms 50
  @max_backoff_ms 5_000

  # SCVD backpressure audit MED-4: the DynamicSupervisor connection fan-in was
  # uncapped. Cap the number of live connections per lane; an accepted socket
  # beyond the cap is closed with a typed refusal + telemetry event. Config
  # override: `config :smalt, :amqp_max_connections, n` (tests use a small cap).
  @default_max_connections 10_000

  @doc "Configured live-connection ceiling per listener lane."
  @spec max_connections() :: pos_integer()
  def max_connections,
    do: Application.get_env(:smalt, :amqp_max_connections, @default_max_connections)

  # -- Public API ---------------------------------------------------------------

  @spec start_link({:sb | :eh, :inet.port_number()} | {:sb | :eh, :inet.port_number(), keyword()}) ::
          {:ok, pid()} | {:error, term()}
  def start_link({name, port}) when name in [:sb, :eh], do: start_link({name, port, []})

  def start_link({name, port, opts}) when name in [:sb, :eh] and is_list(opts) do
    GenServer.start_link(__MODULE__, {name, port, opts},
      name: Keyword.get(opts, :name) || default_name(name)
    )
  end

  @doc "The actual bound port (useful when started with port `0`)."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  defp default_name(:sb), do: Module.concat(__MODULE__, :Sb)
  defp default_name(:eh), do: Module.concat(__MODULE__, :Eh)

  # -- GenServer callbacks ------------------------------------------------------

  @impl true
  def init({name, port, opts}) do
    Process.set_label(%{service: :amqp, role: :listener, correlation_id: name})
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

        Logger.info("[amqp] #{name} listener bound on port #{bound}")

        state = %{
          lane: name,
          mode: name,
          lsock: lsock,
          port: bound,
          conn_sup: Keyword.get(opts, :conn_sup, Smalt.AmqpBroker.conn_sup_name()),
          attempts: 0
        }

        Process.send_after(self(), :accept, 0)
        {:ok, state}

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
        start_connection(socket, state)
        schedule_accept(state, 0)

      {:error, :timeout} ->
        schedule_accept(state, 0)

      {:error, :closed} ->
        {:stop, :normal, %{state | lsock: nil}}

      {:error, reason} ->
        attempts = state.attempts + 1

        Logger.warning(
          "[amqp] #{state.lane} accept error #{inspect(reason)} (attempt #{attempts})"
        )

        schedule_accept(%{state | attempts: attempts}, backoff_ms(attempts))
    end
    |> then(fn
      {:noreply, _} = reply -> reply
      reply -> reply
    end)
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Internals ----------------------------------------------------------------

  defp schedule_accept(state, delay_ms) do
    Process.send_after(self(), :accept, delay_ms)
    {:noreply, state}
  end

  defp backoff_ms(attempts), do: min(@base_backoff_ms * 2 ** (attempts - 1), @max_backoff_ms)

  defp start_connection(socket, %{conn_sup: nil}), do: :gen_tcp.close(socket)

  defp start_connection(socket, state) do
    sup = state.conn_sup

    if conn_sup_alive?(sup) and not cap_reached?(sup, state.lane) do
      child = %{
        id: {:connection, make_ref()},
        # Minimal cross-lane unblock (disclosed by the wire-test lane):
        # Smalt.Amqp.Connection.start_link/1 takes a single opts keyword list
        # with a required :socket key; the previous 2-arg form crashed every
        # accepted connection in init (socket closed before header exchange).
        start: {Smalt.Amqp.Connection, :start_link, [[socket: socket, mode: state.mode]]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(sup, child) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          :gen_tcp.close(socket)

          log_once({__MODULE__, :conn_start_failed}, fn ->
            Logger.warning(
              "[amqp] could not start Smalt.Amqp.Connection for #{state.lane} socket: #{inspect(reason)}"
            )
          end)
      end
    else
      :gen_tcp.close(socket)

      log_once({__MODULE__, :conn_sup_down}, fn ->
        Logger.warning(
          "[amqp] conn supervisor #{inspect(sup)} not running; dropping accepted socket"
        )
      end)
    end

    :ok
  end

  # MED-4 cap: count live DynamicSupervisor children; beyond the ceiling the
  # socket is closed (typed refusal) and a counter event is emitted — the
  # listener itself keeps accepting, never crashes.
  @spec cap_reached?(DynamicSupervisor.supervisor(), atom()) :: boolean()
  defp cap_reached?(sup, lane) do
    cap = max_connections()
    active = DynamicSupervisor.count_children(sup)[:active] || 0

    if active >= cap do
      :telemetry.execute([:smalt, :amqp, :connection_refused], %{count: 1}, %{lane: lane})

      Logger.warning(
        "[amqp] #{lane} connection cap reached (#{active}/#{cap}); refusing new connection"
      )

      true
    else
      false
    end
  end

  defp conn_sup_alive?(sup) when is_pid(sup), do: Process.alive?(sup)
  defp conn_sup_alive?(sup) when is_atom(sup), do: Process.whereis(sup) != nil

  defp log_once(key, fun) do
    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      fun.()
    end
  end
end
