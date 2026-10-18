defmodule Smalt.Affidavit.WasmEngine.Supervisor do
  @moduledoc """
  Additive supervised-restart envelope for `Smalt.Affidavit.WasmEngine`
  (v26.10.18 lib redesign Part 1 - zero caller-path sleeps).

  Strategy `:one_for_one`, `max_restarts: 3, max_seconds: 1`. The single
  child is the OWNER: a small GenServer that start_links the named engine
  and then monitors it (never links - a kill-hammer must not consume
  supervisor intensity). Retry classes, all in the owner's OWN mailbox:

    * `:engine_start_failed` (wasmtime NIF teardown window) - send_after
      retry at 100ms doubling capped;
    * abnormal engine death - `:DOWN` then the same own-mailbox retry
      (kill-hammer consumes zero supervisor intensity);
    * artifact-class refusals - doubling backoff capped, bounded budget
      then idle (kick-only): degrades typed, never crash-loops;
    * intentional normal stop - owner idles, no restart.

  Callers observe only typed vocabulary: `{:ok, _}` |
  `{:error, :engine_unavailable}` | `{:error, :artifact_digest_mismatch}` |
  `{:error, {:already_started, _}}` - never raise, never hang.
  """

  use Supervisor

  alias Smalt.Affidavit.WasmEngine

  @owner __MODULE__.Owner

  @doc """
  Re-arm the owner child (typed test/ops seam): stops any live engine
  (normal) so the fresh owner takes ownership, terminates the current
  owner if running, then starts a fresh owner which start_links a new
  engine generation. Returns `{:ok, owner_pid}` or a typed error.
  """
  @spec restore_owner() :: {:ok, pid()} | {:error, term()}
  def restore_owner do
    if pid = Process.whereis(WasmEngine) do
      GenServer.stop(pid, :normal)
      wait_engine_gone(50)
    end

    case Supervisor.terminate_child(__MODULE__, @owner) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, other} -> {:error, other}
    end

    case Supervisor.restart_child(__MODULE__, @owner) do
      {:ok, pid} -> {:ok, pid}
      {:error, other} -> {:error, other}
    end
  end

  @doc "Typed whereis probe, no side effects."
  @spec engine_running?() :: boolean()
  def engine_running?, do: is_pid(Process.whereis(WasmEngine))

  # MINIMAL UNBLOCK FIX (compile-freeze SLA, lane b-js-harness disclosure):
  # application.ex's child spec calls start_link/1, but `use Supervisor`
  # only generates child_spec/1 — every substrate boot in the tree died with
  # {:undef, [start_link, [[]]]} before this clause existed.
  @doc "Start the named supervisor (application.ex child spec seam)."
  @spec start_link(term()) :: {:ok, pid()} | {:error, term()}
  def start_link(arg \\ :ok) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  defp wait_engine_gone(0), do: :ok

  defp wait_engine_gone(tries) do
    if Process.whereis(WasmEngine) do
      # Own-mailbox pacing only: this seam runs on the caller's process, so
      # the poll is a receive-after, never Process.sleep.
      receive do
      after
        20 -> wait_engine_gone(tries - 1)
      end
    else
      :ok
    end
  end

  @impl true
  def init(_) do
    children = [
      %{id: @owner, start: {@owner, :start_link, [:ok]}, restart: :permanent}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 1)
  end
end

defmodule Smalt.Affidavit.WasmEngine.Supervisor.Owner do
  @moduledoc false

  use GenServer

  alias Smalt.Affidavit.WasmEngine

  @name __MODULE__
  @retry_initial_ms 50
  @retry_cap_ms 5_000
  @restart_delay_ms 250
  @max_artifact_retries 5

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  @impl true
  def init(:ok) do
    # Trap exits: the owner start_links the engine (GenServer.start_link
    # always links), so without trapping every engine kill would kill the
    # owner, consume supervisor intensity, and bypass the monitor/restart
    # design. With trapping, engine death arrives as {:EXIT, ...} in THIS
    # mailbox and the own-mailbox restart is the only retry path.
    Process.flag(:trap_exit, true)

    case attempt_start() do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, {:owned, pid, ref, 0}}

      {:passive, _pid} ->
        # already_started passthrough face: the engine was started by
        # someone else (tests, doctor fallback). The owner does not touch
        # the LIVE foreign generation (adoption guard), but it MONITORS the
        # name (monitor-by-name pins the current generation): on a normal
        # DOWN it idles (intentional stop respected); on an abnormal DOWN
        # it reclaims via the own-mailbox restart.
        ref = Process.monitor(WasmEngine)
        {:ok, {:passive, ref}}

      {:refused, err} ->
        refused_init(err)
    end
  end

  @impl true
  def handle_info(:retry_start, state) do
    case attempt_start() do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:noreply, {:owned, pid, ref, 0}}

      {:passive, _pid} ->
        # Re-probe raced a foreign start: monitor that generation.
        ref = Process.monitor(WasmEngine)
        {:noreply, {:passive, ref}}

      {:refused, err} ->
        handle_refused(err, state)
    end
  end

  def handle_info({:engine_kick, _from}, state) do
    # Doctor seam: immediate attempt on demand; pending send_after is
    # tolerated (attempt_start re-probes whereis).
    send(self(), :retry_start)
    {:noreply, state}
  end

  # Owned engine died. Normal = intentional stop (tests, teardown): idle.
  # Abnormal = crash/kill: own-mailbox restart (supervised retry face).
  def handle_info({:DOWN, ref, :process, _pid, :normal}, {:passive, ref}) do
    {:noreply, :idle}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, {:passive, ref}) do
    # Foreign-owned generation died abnormally: the supervisor RECLAIMS
    # the engine (own-mailbox restart). Without this, a kill of a
    # worker/test-owned generation leaves the surface down forever.
    require Logger
    Logger.warning("WasmEngine owner: foreign generation died (#{inspect(reason)}); reclaiming")
    send_after_restart()
    {:noreply, {:restarting, @restart_delay_ms, 0}}
  end

  # Linked-engine death (owner-owned generation): with trap_exit, arrives
  # here instead of killing the owner.
  def handle_info({:EXIT, pid, :normal}, {:owned, pid, _ref, _n}) do
    {:noreply, :idle}
  end

  def handle_info({:EXIT, pid, reason}, {:owned, pid, _ref, _n}) do
    require Logger
    Logger.warning("WasmEngine owner: engine died (#{inspect(reason)}); restarting in-mailbox")
    send_after_restart()
    {:noreply, {:restarting, @restart_delay_ms, 0}}
  end

  def handle_info({:DOWN, ref, :process, pid, :normal}, {:owned, pid, ref, _n}) do
    {:noreply, :idle}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, {:owned, pid, ref, _n}) do
    # reason logged once for observability; restart is own-mailbox, not a
    # supervisor-intensity consumer (kill-hammer safe by construction).
    require Logger
    Logger.warning("WasmEngine owner: engine died (#{inspect(reason)}); restarting in-mailbox")
    send_after_restart()
    {:noreply, {:restarting, @restart_delay_ms, 0}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- internals -----------------------------------------------------------

  defp attempt_start do
    case WasmEngine.start_link([]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:passive, pid}
      {:error, _} = err -> {:refused, err}
    end
  end

  defp refused_init(err) do
    if engine_start_failed_class?() do
      # NIF-teardown class: brief in-mailbox spacing then a supervised
      # stop so the restart IS a supervisor-consumed retry (intensity
      # 3/1s stays the crash ceiling; the receive-after spaces attempts
      # past the NIF teardown window without a caller-path sleep).
      receive do
      after
        @restart_delay_ms -> {:stop, :engine_start_failed, nil}
      end
    else
      # Artifact class: stay alive, retry in OWN mailbox (bounded budget).
      send_after_retry(@retry_initial_ms)
      {:ok, {:retrying, @retry_initial_ms, 1, inspect(err)}}
    end
  end

  defp handle_refused(err, state) do
    if engine_start_failed_class?() do
      # Same spacing face as init: own-mailbox receive-after before the
      # supervised stop so attempts stay spaced past the NIF window.
      receive do
      after
        @restart_delay_ms -> {:stop, :engine_start_failed, state}
      end
    else
      {last_state, n, _last_err} = normalize(state)

      if n >= @max_artifact_retries do
        # Budget exhausted: idle (kick-only) - a permanently bad artifact
        # must degrade, not loop forever.
        {:noreply, :idle}
      else
        delay = backoff(last_state)
        send_after_retry(delay)
        {:noreply, {:retrying, delay, n + 1, inspect(err)}}
      end
    end
  end

  # {:retrying, delay, n, last_err} | :idle | :passive -> {delay, n}
  defp normalize({:retrying, delay, n, _err}), do: {delay, n, nil}
  defp normalize(_other), do: {@retry_initial_ms, 0, nil}

  defp backoff(delay), do: min(delay * 2, @retry_cap_ms)

  defp engine_start_failed_class? do
    WasmEngine.last_init_refusal() == :engine_start_failed
  end

  defp send_after_retry(delay), do: Process.send_after(self(), :retry_start, delay)
  defp send_after_restart, do: Process.send_after(self(), :retry_start, @restart_delay_ms)
end
