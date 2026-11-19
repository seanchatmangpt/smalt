defmodule Smalt.Aoq.Quic.Listener do
  @moduledoc """
  Supervised QUIC listener (FNOX-SJ-QUIC-1).

  Owns the server engine and listener resource from `Smalt.Aoq.Quic.serve/4`
  and runs an accept loop in a linked acceptor process. Each accepted
  connection is handed to a handler process under a linked
  `Task.Supervisor`. The default handler accepts one bi-directional stream and
  echoes every received payload until the stream refuses.

  Crash law: the acceptor and the task supervisor are linked to this process,
  so a kill of the listener tears the whole subtree down and the owning
  supervisor restarts it. Binding the UDP port may lag the previous owner's
  resource release, so a refused bind is retried on a bounded
  `Process.send_after` schedule (scheduling, not readiness-by-clock: readiness
  is the `:ready` state reached on a successful serve).

  Options: `:port` (required), `:cert_der`, `:key_der`, `:ca_der` (required
  binaries), `:handler` (`(conn -> any)`, default echo), `:name`
  (default `#{inspect(__MODULE__)}`), `:accept_timeout_ms` (default 100),
  `:stream_idle_ms` (default 500, bound for the default echo handler),
  `:bind_retries` (default 400, 50 ms apart).
  """

  use GenServer

  alias Smalt.Aoq.Quic

  @bind_retry_ms 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Returns `:ready` once the UDP listener is bound, else `:binding`."
  @spec status(GenServer.server()) :: :ready | :binding
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Default connection handler: accept one bi-directional stream and echo
  payloads until the stream refuses.
  """
  @spec echo_handler(Quic.conn()) :: :ok
  def echo_handler(conn), do: echo_handler(conn, 10_000)

  @doc """
  Echo handler with an explicit idle bound (ms) on stream accept and recv.
  A short bound lets a killed listener's handler tasks drop their connection
  resources (blocked dirty NIF calls cannot be interrupted) so the UDP port
  is released promptly.
  """
  @spec echo_handler(Quic.conn(), pos_integer()) :: :ok
  def echo_handler(conn, idle_ms) do
    with {:ok, stream} <- Quic.accept_bi(conn, idle_ms) do
      echo_loop(stream, idle_ms)
    end

    :ok
  end

  defp echo_loop(stream, idle_ms) do
    case Quic.stream_recv(stream, idle_ms) do
      {:ok, bytes} ->
        case Quic.stream_send(stream, bytes) do
          :ok -> echo_loop(stream, idle_ms)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def init(opts) do
    state = %{
      opts: opts,
      status: :binding,
      engine: nil,
      listener: nil,
      tasks: nil,
      acceptor: nil,
      retries: Keyword.get(opts, :bind_retries, 400)
    }

    Process.flag(:trap_exit, true)

    {:ok, state, {:continue, :bind}}
  end

  @impl true
  def handle_continue(:bind, state), do: bind(state)

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:bind, state), do: bind(state)
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state),
    do: {:stop, {:acceptor_exit, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{acceptor: acceptor, tasks: tasks}) do
    # Cooperative stop: unlink + kill the loop and handlers so their NIF
    # resource refs (listener, conns) are dropped as soon as the dirty calls
    # return (bounded by the short accept/idle timeouts).
    if is_pid(acceptor) do
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
    end

    if is_pid(tasks) do
      Process.unlink(tasks)
      Process.exit(tasks, :shutdown)
    end

    :ok
  end

  defp bind(%{opts: opts} = state) do
    with {:ok, engine} <- Quic.open(0, Keyword.fetch!(opts, :ca_der)),
         {:ok, listener} <-
           Quic.serve(
             engine,
             Keyword.fetch!(opts, :port),
             Keyword.fetch!(opts, :cert_der),
             Keyword.fetch!(opts, :key_der)
           ) do
      {:ok, tasks} = Task.Supervisor.start_link()
      idle = Keyword.get(opts, :stream_idle_ms, 500)

      handler =
        case Keyword.fetch(opts, :handler) do
          {:ok, custom} -> custom
          :error -> fn conn -> echo_handler(conn, idle) end
        end

      timeout = Keyword.get(opts, :accept_timeout_ms, 100)
      acceptor = spawn_link(fn -> accept_loop(listener, tasks, handler, timeout) end)

      {:noreply,
       %{
         state
         | status: :ready,
           engine: engine,
           listener: listener,
           tasks: tasks,
           acceptor: acceptor
       }}
    else
      {:error, _} = refusal ->
        if state.retries > 0 do
          # SLEEP-CLASS: SCHEDULING - bounded bind retry while the prior owner's
          # UDP resource is released by the runtime.
          Process.send_after(self(), :bind, @bind_retry_ms)
          {:noreply, %{state | retries: state.retries - 1}}
        else
          {:stop, {:bind_failed, refusal}, state}
        end
    end
  end

  defp accept_loop(listener, tasks, handler, timeout) do
    case Quic.accept(listener, timeout) do
      {:ok, conn} ->
        {:ok, pid} = Task.Supervisor.start_child(tasks, fn -> handler.(conn) end)
        _ = pid
        accept_loop(listener, tasks, handler, timeout)

      {:error, _timeout_or_refusal} ->
        accept_loop(listener, tasks, handler, timeout)
    end
  end
end
