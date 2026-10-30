defmodule Smalt.Posh.Port do
  @moduledoc """
  POSH-005 phase change (latent → gas): runs the real posh Go binary as a
  BEAM port so the membrane is a supervised OS process, not a latent build
  artifact.

  The wrapper derives a posh.yaml-equivalent config (socket path; the
  binary's stderr rides `:stderr_to_stdout` on the port, so the port stream
  IS the log dest) from the `:socket_path`/`:bin_path` opts, opens the port
  with `-config`, and gives supervision-friendly semantics:

  - absent `:socket_path` or `:bin_path` opts → module not started (same
    `Keyword.fetch!` pattern as `Smalt.Posh.Client`)
  - `restart: :transient` — an abnormal exit restarts, a clean stop does not
  - boot failure (missing binary / early exit / boot timeout) →
    `start_link` returns `{:error, {:port, reason}}`, typed
  - graceful stop: SIGTERM the os pid, then `Port.close`

  No `Process.sleep`: boot readiness is a bounded poll on the real
  observable (the socket file), stepped by a receive-after cadence inside
  init's boot wait.
  """

  use GenServer

  @boot_timeout_ms 5_000
  @boot_poll_ms 20

  # ── API ──────────────────────────────────────────────────────────────

  @doc """
  Options: `:socket_path` (UDS path the membrane binds), `:bin_path`
  (posh binary), `:boot_timeout_ms` (default #{@boot_timeout_ms}).

  A missing `:socket_path`/`:bin_path` raises via `Keyword.fetch!` (module
  not started — supervisor child absent). A MISSING BINARY returns
  `{:error, {:port, {:enoent, bin_path}}}` — typed boot refusal.
  """
  @spec start_link(keyword) :: {:ok, pid} | {:error, {:port, term}}
  def start_link(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)
    bin_path = Keyword.fetch!(opts, :bin_path)
    name = Keyword.get(opts, :name, __MODULE__)

    # Fail-closed, typed: a missing binary refuses boot in the caller's
    # frame, never a hang, never a raw raise.
    if File.exists?(bin_path) do
      GenServer.start_link(__MODULE__, %{
        socket_path: socket_path,
        bin_path: bin_path,
        boot_timeout_ms: Keyword.get(opts, :boot_timeout_ms, @boot_timeout_ms)
      }, name: name)
    else
      {:error, {:port, {:enoent, bin_path}}}
    end
  end

  @doc "Graceful stop: SIGTERM the os pid, then Port.close. Idempotent."
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__) do
    try do
      GenServer.stop(server, :normal)
    catch
      :exit, _ -> :ok
    end
  end

  @doc "Boot state: :up (socket present), :down, or {:boot_failed, reason}."
  @spec status(GenServer.server()) :: :up | :down | {:boot_failed, term}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The os pid of the posh binary, when booted."
  @spec os_pid(GenServer.server()) :: {:ok, charlist | integer} | {:error, :os_pid}
  def os_pid(server \\ __MODULE__), do: GenServer.call(server, :os_pid)

  # ── Supervisor child (POSH-005: start AFTER client, restart transient) ─

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(%{socket_path: socket_path, bin_path: bin_path, boot_timeout_ms: timeout_ms}) do
    cfg_path = config_path(socket_path)
    :ok = write_config(cfg_path, socket_path)
    # Defensive: a stale socket from a previous unclean stop reads as :up.
    File.rm(socket_path)

    port =
      Port.open({:spawn_executable, to_charlist(bin_path)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-config", cfg_path]
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    boot_wait(
      %{socket_path: socket_path, cfg_path: cfg_path, port: port, exit: nil, stopping: false},
      deadline
    )
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_tuple(state), state}
  end

  def handle_call(:os_pid, _from, state), do: {:reply, os_pid_tuple(state.port), state}

  # ── Port messages (this process owns the port) ────────────────────────

  @impl true
  def handle_info({port, {:data, _log_line}}, %{port: port} = state) do
    # Log dest: the binary's stderr/stdout rides the port stream, drained
    # (not buffered) so the pipe never backpressures the membrane.
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    # Any exit is abnormal from the supervisor's view: under restart
    # :transient this restarts the membrane.
    {:stop, {:port, {:exit_status, code}}, %{state | exit: {:exit_status, code}}}
  end

  @impl true
  def terminate(_reason, state) do
    # Terminate path only: bounded exit wait + SIGKILL escalation. Init
    # {:stop, ...} paths (boot timeout / early exit) skip the wait — the
    # boot_wait loop already owns their exit observables.
    graceful_kill(state.port, :await_exit)
    File.rm(state.cfg_path)
    :ok
  end

  # ── internals ────────────────────────────────────────────────────────

  # Bounded boot wait: poll the real observable (the socket file) on a
  # receive-after cadence while consuming port messages. Never Process.sleep.
  defp boot_wait(state, deadline) do
    cond do
      File.exists?(state.socket_path) ->
        {:ok, state}

      state.exit != nil ->
        {:stop, {:port, state.exit}, state}

      System.monotonic_time(:millisecond) >= deadline ->
        graceful_kill(state.port)
        {:stop, {:port, {:boot_timeout, state.socket_path}}, state}

      true ->
        receive do
          {port, {:data, _}} when port == state.port ->
            boot_wait(state, deadline)

          {port, {:exit_status, code}} when port == state.port ->
            graceful_kill(port)
            {:stop, {:port, {:exit_status, code}}, state}
        after
          @boot_poll_ms ->
            boot_wait(state, deadline)
        end
    end
  end

  defp status_tuple(%{socket_path: path}),
    do: if(File.exists?(path), do: :up, else: :down)

  defp os_pid_tuple(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> {:ok, pid}
      nil -> {:error, :os_pid}
    end
  end

  # Terminate path: SIGTERM, then Port.close, then a bounded receive on the
  # real exit_status observable; SIGKILL only if the bounded wait expires.
  # No Process.sleep — the wait IS a receive-after deadline.
  defp graceful_kill(port, mode \\ :no_wait) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        _ = :os.cmd(~c"kill -TERM #{pid} 2>/dev/null")

      nil ->
        :ok
    end

    _ = Port.close(port)

    if mode == :await_exit, do: await_exit_or_escalate(port)

    :ok
  end

  # Bounded (~500ms) wait for the port's {:exit_status, _} message; on
  # timeout escalate to SIGKILL via the same :os.cmd path. Terminate path
  # only — never on init {:stop, ...} paths.
  defp await_exit_or_escalate(port) do
    receive do
      {^port, {:exit_status, _code}} -> :ok
    after
      500 ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> _ = :os.cmd(~c"kill -9 #{pid} 2>/dev/null")
          nil -> :ok
        end

        :ok
    end
  end

  # posh.yaml-equivalent: the only required key is `socket`; the binary's
  # stderr→stdout stream on the port is the log dest (documented above).
  defp write_config(cfg_path, socket_path) do
    yaml = """
    # Written by Smalt.Posh.Port (posh.yaml-equivalent, fail-closed schema).
    socket: #{socket_path}
    tcp_addr: ""
    egress_allowlist: []
    """

    File.write!(cfg_path, yaml)
    :ok
  end

  defp config_path(socket_path) do
    Path.join(System.tmp_dir!(), "posh-port-#{hash(socket_path)}.yaml")
  end

  defp hash(bin), do: bin |> :erlang.md5() |> Base.encode16(case: :lower)
end
