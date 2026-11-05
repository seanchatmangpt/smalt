defmodule Smalt.Aoq.Session do
  @moduledoc """
  AoQ session: a pinned, tail-recursive recv loop over a CONNECTED
  `:socket` UDP socket (the per-peer face the Listener hands off to —
  aq-architecture-spec §1.3).

  The session process is a plain process (not a GenServer). It optionally
  pins to a scheduler core (cfg `:pin`: `nil` skip / `true`
  `Smalt.Aoq.Scheduler.next_core()` / integer `Scheduler.pin(n)`), then
  lives entirely in a `:socket.recvmsg` loop: the wait is a blocking
  `:socket` call with a per-call timeout, re-armed until a
  `System.monotonic_time` idle deadline lapses — no `Process.sleep`
  anywhere (SLEEP-CLASS: POLL-STEP, the runtime owns the wait).

  Frames are delivered to the cfg `:owner` process (required) via the
  handler (`cfg[:handler]`, default `send(owner, {:aoq_session_frame,
  payload})`). When the idle deadline lapses or the socket errors, the
  session records a typed refusal (`{:transport_refusal, reason}`, same
  shape as `Smalt.Aoq.Transport`), notifies the owner with
  `{:aoq_session_done, refusal}`, closes the socket, and exits `:normal`.
  The loop is tail-recursive: stack usage is constant under load.
  """

  @poll_interval 20
  @default_idle_timeout 5_000
  @buf_size 2048

  @typedoc "Connected `:socket` handle (as opened by `Smalt.Aoq.Transport.open/3`)."
  @type socket :: :socket.socket()

  def start_link(cfg) when is_list(cfg) do
    pid = spawn_link(fn -> init(cfg) end)
    {:ok, pid}
  end

  @doc """
  The session's current scheduler id (`:erlang.process_info/2` — the pin
  witness), or nil if the process is gone.
  """
  @spec scheduler_id(pid) :: non_neg_integer() | nil
  def scheduler_id(pid) do
    case :erlang.process_info(pid, :scheduler_id) do
      {:scheduler_id, id} -> id
      nil -> nil
    end
  end

  @doc "Stop the session process."
  @spec stop(pid) :: :ok
  def stop(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  ##

  defp init(cfg) do
    sock = Keyword.fetch!(cfg, :socket)
    owner = Keyword.fetch!(cfg, :owner)
    idle_ms = Keyword.get(cfg, :idle_timeout, @default_idle_timeout)
    handler = Keyword.get(cfg, :handler)
    pin(Keyword.get(cfg, :pin))

    handler = handler || fn payload -> send(owner, {:aoq_session_frame, payload}) end
    loop(sock, owner, handler, idle_ms, deadline(idle_ms))
  end

  # Tail-recursive recv loop (constant stack under load). The wait is a
  # blocking recvmsg with per-call timeout; `:timeout` re-arms until the
  # monotonic idle deadline lapses, then refuses typed.
  defp loop(sock, owner, handler, idle_ms, deadline) do
    case :socket.recvmsg(sock, @buf_size, 0, @poll_interval) do
      {:ok, %{iovec: iovec}} ->
        payload = iovec |> List.wrap() |> :erlang.iolist_to_binary()
        handler.(payload)
        loop(sock, owner, handler, idle_ms, deadline(idle_ms))

      {:error, :timeout} ->
        if System.monotonic_time(:millisecond) >= deadline do
          done(sock, owner, {:transport_refusal, :recv_timeout})
        else
          loop(sock, owner, handler, idle_ms, deadline)
        end

      {:error, reason} ->
        done(sock, owner, {:transport_refusal, reason})

      other ->
        done(sock, owner, {:transport_refusal, other})
    end
  end

  defp done(sock, owner, refusal) do
    _ = :socket.close(sock)
    send(owner, {:aoq_session_done, refusal})
    exit(:normal)
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
