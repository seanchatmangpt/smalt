defmodule Smalt.Aoq.Listener do
  @moduledoc """
  AoQ wire face — datagram ingress (phase-1: Bandit HTTP out, datagram face
  in).

  A plain process (not a GenServer) that lives in a tail-recursive
  `:socket.recvmsg` loop on a UDP socket bound to `127.0.0.1` loopback port
  `cfg[:port]` (`0` = ephemeral, the test contract). Each datagram payload
  is handed to `Smalt.Aoq.WorkerPool.submit/1` (cfg `:sink` seam defaults
  to exactly that). The loop's wait is a blocking `:socket` call with a
  per-call timeout — the runtime schedules the process away while it has
  nothing to do (no-sleep law: no `Process.sleep` anywhere). An idle
  deadline (`System.monotonic_time`, reset per frame) lapses into a typed
  refusal recorded via `refusal/0`; the process then exits `:shutdown` so
  the supervisor restarts it.

  Readiness: `local_port/0` is the bound port (nil before bind).

  Optional scheduler pinning (cfg `:pin`): `nil` → skip, `true` →
  `Smalt.Aoq.Scheduler.next_core()`, integer → `Scheduler.pin(n)`.
  """

  @poll_interval 20
  @default_idle_timeout 30_000
  @buf_size 2048

  def start_link(cfg) do
    pid = spawn_link(fn -> init(cfg) end)
    {:ok, pid}
  end

  def child_spec(id \\ __MODULE__, cfg) do
    %{
      id: id,
      start: {__MODULE__, :start_link, [cfg]},
      type: :worker,
      shutdown: 10_000
    }
  end

  @doc """
  Readiness observable: the bound local port (`nil` before bind, integer
  in `1..65_535` after).
  """
  @spec local_port() :: :inet.port_number() | nil
  def local_port do
    :persistent_term.get({__MODULE__, :local_port}, nil)
  end

  @doc """
  Typed refusal (`{:transport_refusal, reason}`, same shape as
  `Smalt.Aoq.Transport`) recorded when the loop gave up; `nil` while live.
  """
  @spec refusal() :: {:transport_refusal, term} | nil
  def refusal do
    :persistent_term.get({__MODULE__, :refusal}, nil)
  end

  @doc "Stop the listener process."
  @spec stop(pid) :: :ok
  def stop(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  ##

  defp init(cfg) do
    idle_ms = Keyword.get(cfg, :idle_timeout, @default_idle_timeout)
    sink = Keyword.get(cfg, :sink, &Smalt.Aoq.WorkerPool.submit/1)

    case bind(cfg) do
      {:ok, sock, port} ->
        :persistent_term.put({__MODULE__, :local_port}, port)
        :persistent_term.put({__MODULE__, :refusal}, nil)
        pin(Keyword.get(cfg, :pin))
        loop(sock, sink, idle_ms, deadline(idle_ms))

      {:error, reason} ->
        :persistent_term.put({__MODULE__, :local_port}, nil)
        :persistent_term.put({__MODULE__, :refusal}, {:transport_refusal, reason})
        exit({:listener_bind_refused, reason})
    end
  end

  defp bind(cfg) do
    port = Keyword.fetch!(cfg, :port)

    with {:ok, sock} <- :socket.open(:inet, :dgram, :udp),
         :ok <- :socket.bind(sock, %{family: :inet, addr: {127, 0, 0, 1}, port: port}) do
      case :socket.sockname(sock) do
        {:ok, %{port: bound}} -> {:ok, sock, bound}
        other -> {:error, other}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Tail-recursive recv loop. The wait is a blocking recvmsg with per-call
  # timeout; `:timeout` re-arms until the monotonic idle deadline lapses,
  # then refuses typed (SLEEP-CLASS: POLL-STEP — the runtime owns the wait).
  defp loop(sock, sink, idle_ms, deadline) do
    case :socket.recvmsg(sock, @buf_size, 0, @poll_interval) do
      {:ok, %{iovec: iovec}} ->
        payload = iovec |> List.wrap() |> :erlang.iolist_to_binary()
        handoff(sink, payload)
        loop(sock, sink, idle_ms, deadline(idle_ms))

      {:error, :timeout} ->
        if System.monotonic_time(:millisecond) >= deadline do
          give_up(sock, :recv_timeout)
        else
          loop(sock, sink, idle_ms, deadline)
        end

      {:error, reason} ->
        give_up(sock, reason)

      other ->
        give_up(sock, other)
    end
  end

  defp handoff(sink, payload) do
    case sink.(payload) do
      {:ok, _} -> :ok
      {:error, reason} -> :logger.warning("AoQ listener handoff refused: ~p", [reason])
      _ -> :ok
    end
  end

  defp give_up(sock, reason) do
    :socket.close(sock)
    :persistent_term.put({__MODULE__, :refusal}, {:transport_refusal, reason})
    exit(:shutdown)
  end

  # cfg :pin — nil skips, true takes next_core(), integer pins that core.
  defp pin(nil), do: :ok

  defp pin(true), do: pin(Smalt.Aoq.Scheduler.next_core())

  defp pin(core) when is_integer(core) and core >= 1 do
    _ = Smalt.Aoq.Scheduler.pin(core)
    :ok
  end

  defp deadline(idle_ms), do: System.monotonic_time(:millisecond) + idle_ms
end
