defmodule Smalt.ArmGateway.LRO.Notifier do
  @moduledoc """
  Explicit completion-signal hub for ARM LRO operations (v26.10.18 lib
  redesign, Part 2 of
  `docs/jira/v26.10.18/rewrite-drafts/lib-redesign-wasm-lro.md`).

  SIGNAL layer only — never writes the store. Every persistence of a
  terminal transition flows through the single terminal writer, the
  `Smalt.ArmGateway.LRO.Sweeper` process (the only flip-path component that
  invokes the public `LRO.evaluate/2` / `LRO.fail_closed/2` persistence
  functions), and the sweeper publishes the terminal through this GenServer
  via an explicit cast so monitored waiters (`LRO.await/3`) wake on the
  signal instead of polling.

  - Waiter registry `op_id -> ref -> {pid, monitor_ref}`, monitored, dead
    waiters reaped on `:DOWN`.
  - On registration while InProgress, a one-shot `:due_check` timer fires at
    the record's remaining delay: due InProgress -> cast the single writer
    `{:flip_due, op_id}`; already-terminal store record -> published
    read-only; malformed -> writer fail-closed repair cast.
  - Deny-by-default registration: with `expected_sub`, the record's `id`
    must prove ownership (`LRO.scoped?/2`) or the registration is refused
    (`:error, :denied`); missing/malformed records refuse `:not_found`.
  - Fail-safe, never correctness: `LRO.await/3` monitors this process and
    falls back to bounded store polling on `:DOWN`; the sweeper still flips
    at rest regardless of this process.
  """

  use GenServer

  alias Smalt.ArmGateway.LRO
  alias Smalt.ArmGateway.LRO.Sweeper
  alias Smalt.Store

  @await_msg :lro_terminal

  @doc "Terminal message tag delivered to waiters: `{:lro_terminal, op_id, record}`."
  def await_msg, do: @await_msg

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{waiters: %{}}}

  @doc """
  Registers a waiter for `op_id`. Replies:

    - `{:ok, nil, {:terminal, record}}` — already terminal; no waiter entry
      is created (the caller completes from this record directly)
    - `{:ok, ref, nil}` — waiter registered (monitored); due-check timer
      scheduled while the record is InProgress
    - `{:error, :not_found}` — no record (or a malformed record) under
      `op_id`
    - `{:error, :denied}` — `expected_sub` given and ownership not proven
    - `{:error, :notifier_down}` — Notifier unreachable (await falls back
      to bounded store polling)
  """
  def register(op_id, expected_sub) when is_binary(op_id) do
    try do
      GenServer.call(__MODULE__, {:register, op_id, expected_sub})
    catch
      :exit, _ -> {:error, :notifier_down}
    end
  end

  @doc "Removes a waiter created by `register/2` (the await-timeout path)."
  def unregister(op_id, ref) do
    try do
      GenServer.call(__MODULE__, {:unregister, op_id, ref})
    catch
      :exit, _ -> :ok
    end
  end

  @impl true
  def handle_call({:register, op_id, expected_sub}, from, state) do
    case Store.get(:smalt_operations, op_id) do
      {:ok, %{"status" => status} = record} when is_binary(status) and status != "InProgress" ->
        if expected_sub && not LRO.scoped?(record, expected_sub) do
          # Deny-by-default applies to terminal records too: a foreign
          # subscriber never receives the record, terminal or not.
          {:reply, {:error, :denied}, state}
        else
          # Already terminal: no waiter entry is created — the caller
          # completes from this record directly.
          {:reply, {:ok, nil, {:terminal, record}}, state}
        end

      {:ok, record}
      when not is_map_key(record, "status") or
             not is_binary(:erlang.map_get("status", record)) ->
        # Malformed (status-less / non-binary status): route the fail-closed
        # repair through the single writer (which publishes on completion)
        # and refuse registration — the await caller's store-first get_op
        # already returned the fail-closed view.
        # (W2 compile-freeze unblock: guard-legal :erlang.map_get/2 replaces
        # Access.get/2 in guard; semantics identical — disclosed per SLA.)
        GenServer.cast(Sweeper, {:fail_closed, op_id, record})
        {:reply, {:error, :not_found}, state}

      {:ok, record} ->
        if expected_sub && not LRO.scoped?(record, expected_sub) do
          # Deny-by-default: no proof of ownership, no waiter registration.
          {:reply, {:error, :denied}, state}
        else
          ref = make_ref()
          {pid, _tag} = from
          mref = Process.monitor(pid)
          state = put_waiter(state, op_id, ref, pid, mref)

          schedule_due_check(record, op_id)
          {:reply, {:ok, ref, nil}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unregister, op_id, ref}, _from, state) do
    state =
      case get_in(state.waiters, [op_id, ref]) do
        {_pid, mref} ->
          true = Process.demonitor(mref, [:flush])
          remove_waiter(state, op_id, ref)

        nil ->
          state
      end

    {:reply, :ok, state}
  end

  # Sweeper -> Notifier explicit publish after the single-writer persist.
  @impl true
  def handle_cast({:terminal, op_id, record}, state) do
    {:noreply, wake(op_id, {@await_msg, op_id, record}, state)}
  end

  @impl true
  def handle_info({:due_check, op_id}, state) do
    case Store.get(:smalt_operations, op_id) do
      {:ok, %{"status" => "InProgress"} = record} ->
        if LRO.due?(record) do
          # Signal the SINGLE writer; the Notifier never persists.
          GenServer.cast(Sweeper, {:flip_due, op_id})
        end

        {:noreply, state}

      {:ok, %{"status" => status} = record} when is_binary(status) ->
        # Store already terminal (a writer flip the waiter's signal missed):
        # publish the store record. Read-only.
        {:noreply, wake(op_id, {@await_msg, op_id, record}, state)}

      {:ok, malformed_record} ->
        GenServer.cast(Sweeper, {:fail_closed, op_id, malformed_record})
        {:noreply, state}

      :error ->
        # Evicted or never existed: no signal. An await on a vanished op
        # times out typed from the store-first/fallback path.
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    {:noreply, drop_by_monitor(state, mref)}
  end

  # -- internals ----------------------------------------------------------------

  # Schedules the one-shot due check at the record's remaining delay (>= 0).
  defp schedule_due_check(
         %{"startedAtMs" => started, "delayMs" => delay, "status" => status},
         op_id
       )
       when is_integer(started) and is_integer(delay) and status == "InProgress" do
    remaining = max(0, started + delay - System.system_time(:millisecond))
    Process.send_after(self(), {:due_check, op_id}, remaining + 1)
  end

  defp schedule_due_check(_record, _op_id), do: :ok

  defp put_waiter(state, op_id, ref, pid, mref) do
    waiters =
      Map.update(state.waiters, op_id, %{ref => {pid, mref}}, fn refs ->
        Map.put(refs, ref, {pid, mref})
      end)

    %{state | waiters: waiters}
  end

  defp remove_waiter(state, op_id, ref) do
    case Map.fetch(state.waiters, op_id) do
      {:ok, refs} ->
        case Map.delete(refs, ref) do
          empty when empty == %{} -> %{state | waiters: Map.delete(state.waiters, op_id)}
          rest -> %{state | waiters: Map.put(state.waiters, op_id, rest)}
        end

      :error ->
        state
    end
  end

  # Wakes every waiter registered under op_id, demonitors each, and drops
  # the op's registry entry. Multiple waiters per op are all woken.
  defp wake(op_id, msg, state) do
    case Map.fetch(state.waiters, op_id) do
      {:ok, refs} ->
        Enum.each(refs, fn {_ref, {pid, mref}} ->
          true = Process.demonitor(mref, [:flush])
          send(pid, msg)
        end)

        %{state | waiters: Map.delete(state.waiters, op_id)}

      :error ->
        state
    end
  end

  defp drop_by_monitor(state, mref) do
    Enum.reduce(state.waiters, state, fn {op_id, refs}, acc ->
      case Enum.find(refs, fn {_ref, {_pid, m}} -> m == mref end) do
        {ref, _waiter} -> remove_waiter(acc, op_id, ref)
        nil -> acc
      end
    end)
  end
end
