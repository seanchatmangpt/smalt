defmodule Smalt.Aoq.Session do
  @moduledoc """
  AoQ session: a pinned, tail-recursive recv loop over a CONNECTED
  `:socket` UDP socket (the per-peer face — aq-architecture-spec §1.3).

  A plain process (not a GenServer). Pinning happens inside the process;
  the pin witness is the re-pin binding pushed to the owner at init
  (`{:aoq_session_pinned, core}`) and stored in the process dictionary
  (readable via `scheduler_id/1` — this OTP build exposes no
  `scheduler_id` process_info item, so the witness is a re-pin binding,
  not a process_info read).

  cfg:
  - `:socket` (required) — connected `:socket` handle
  - `:owner` (required) — pid receiving `{:aoq_session_frame, payload}`,
    `{:aoq_session_pinned, core}` (when pinned), `{:aoq_session_done, refusal}`
  - `:pin` — `nil` skip / `true` -> `Scheduler.next_core()` / integer core
  - `:handler` — fun/1 over each frame payload (default: send to owner)
  - `:idle_timeout` — idle deadline ms (default 5_000)
  """

  @poll_interval 20
  @default_idle_timeout 5_000
  @buf_size 2048

  @typedoc "Connected :socket handle (as opened by Smalt.Aoq.Transport.open/3)."
  @type socket :: :socket.socket()

  def start_link(cfg) when is_list(cfg) do
    pid = spawn_link(fn -> init(cfg) end)
    {:ok, pid}
  end

  @doc """
  The session's pinned scheduler core — the pin witness. The binding is
  set inside the process at init (a re-pin returns the prior binding)
  and stored in the process dictionary; nil when pin: nil.
  """
  @spec scheduler_id(pid) :: non_neg_integer() | nil
  def scheduler_id(pid) do
    case :erlang.process_info(pid, :dictionary) do
      {:dictionary, kw} when is_list(kw) ->
        case List.keyfind(kw, {__MODULE__, :pinned_core}, 0) do
          {_k, core} -> core
          nil -> nil
        end

      _ ->
        nil
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
    handler = handler || fn payload -> send(owner, {:aoq_session_frame, payload}) end

    case pin(Keyword.get(cfg, :pin)) do
      nil ->
        loop(sock, owner, handler, idle_ms, deadline(idle_ms))

      core ->
        Process.put({__MODULE__, :pinned_core}, core)
        send(owner, {:aoq_session_pinned, core})
        loop(sock, owner, handler, idle_ms, deadline(idle_ms))
    end
  end

  # Tail-recursive recv loop (constant stack under load). The wait is a
  # blocking recvmsg with per-call timeout; `:timeout` re-arms until the
  # monotonic idle deadline lapses, then refuses typed
  # (SLEEP-CLASS: POLL-STEP — the runtime owns the wait).
  defp loop(sock, owner, handler, idle_ms, deadline) do
    case :socket.recvmsg(sock, @buf_size, 0, @poll_interval) do
      {:ok, %{iov: iovec}} ->
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
  defp pin(nil), do: nil
  defp pin(true), do: do_pin(Smalt.Aoq.Scheduler.next_core())
  defp pin(core) when is_integer(core) and core >= 1, do: do_pin(core)

  # Set the scheduler binding inside the process; the re-pin returns the
  # prior binding — the core — which is the pin witness.
  defp do_pin(core) do
    _ = :erlang.process_flag(:scheduler, core)
    :erlang.process_flag(:scheduler, core)
  end

  defp deadline(idle_ms), do: System.monotonic_time(:millisecond) + idle_ms
end
