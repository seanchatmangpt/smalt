defmodule Smalt.Amqp.Sweeper do
  @moduledoc """
  Periodic (250 ms, configurable via `Application.get_env(:smalt, :amqp_sweeper_tick_ms, 250)`)
  maintenance tick for the AMQP broker:

  - `Smalt.Amqp.LockManager` lock/session-lock expiry sweep (`sweep/0`),
  - `Smalt.Amqp.QueueStore` expired-message-lock release sweep (`sweep/0`),
  - `Smalt.Amqp.CbsRouter` CBS token GC (`gc/0`),
  - `Smalt.Messaging.EventHubs` expired processing-claim GC (`sweep/0`).

  Fail-closed contract: all sibling sweep functions exist (concurrent-landing
  tolerance was retired). A sibling failure raises and crashes this GenServer;
  the supervisor restart is the honest signal — no log-and-continue, no skip.
  """

  use GenServer

  # Former @default_tick_ms 250 now lives ONLY in the ontology
  # (smalt:ck-amqp-sweeper-tick-ms) via the Smalt.Config projection.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run one sweep pass immediately (also invoked by the 250 ms tick)."
  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep)
  end

  @doc """
  One sweep pass. Calls every sibling sweep function directly; any failure
  propagates (crashing the caller) instead of being logged and skipped.
  """
  def run_pass do
    if :ets.info(:smalt_sb_locks) == :undefined or :ets.info(:smalt_sb_messages) == :undefined do
      # AZB-20 interop unblock (disclosed in the AZB-20 receipt): on an
      # integration-only plane boot (SMALT_PLANES=integration) the data-plane
      # Store — owner of the smalt_sb_* ETS tables — is not running. The
      # sweep pass no-ops until the tables exist instead of crash-looping the
      # whole integration plane (same topology-defect class as the AZB-20
      # LRO Sweeper guard).
      :ok
    else
      do_run_pass()
    end
  end

  defp do_run_pass do
    # SHIM-COURT R245 (audit Finding 3): capture expired message-lock token rows
    # BEFORE the sweeps delete them, then re-put them (tombstone grace) AFTER
    # QueueStore.sweep has re-availed the message rows. The pinned
    # ManagementRpc contract (lock_manager.ex moduledoc: expired token →
    # 410 :lock_lost, unknown → 404 :not_found) must survive a sweep pass:
    # LockManager.sweep/0 deletes expired :message token rows as orphans and
    # QueueStore.sweep/0 releases the token on re-avail, so without the grace
    # a client renewing a just-expired token got 404 instead of 410. Grace is
    # bounded (first-swept + amqp_sweeper_lock_grace_ms, default 30_000) so
    # tombstones never live forever; past grace the row is left deleted and
    # renew correctly answers 404 for a long-dead token.
    doomed = doomed_message_locks()

    Smalt.Amqp.LockManager.sweep()
    Smalt.Amqp.QueueStore.sweep()
    reinsert_message_tombstones(doomed)

    # CbsRouter is the one legitimately optional sibling: some test boot
    # modes never start it (it is only spun up with CBS transfer support),
    # so a hard call would crash the sweep on every such boot. Everything
    # else is fail-closed.
    if GenServer.whereis(Smalt.Amqp.CbsRouter) do
      Smalt.Amqp.CbsRouter.gc()
    end

    Smalt.Messaging.EventHubs.sweep()
    :ok
  end

  # -- Message-lock tombstone grace (audit Finding 3) ---------------------------

  @tombstone_table :smalt_sb_sweeper_lock_tombstones
  @default_grace_ms 30_000

  defp grace_ms do
    Application.get_env(:smalt, :amqp_sweeper_lock_grace_ms, @default_grace_ms)
  end

  # Read-only ETS capture of expired :message token rows about to be swept.
  defp doomed_message_locks do
    if :ets.info(:smalt_sb_locks) == :undefined do
      []
    else
      now = System.system_time(:millisecond)

      :smalt_sb_locks
      |> :ets.match_object({:_, :_})
      |> Enum.filter(fn {_token, lock} ->
        is_map(lock) and lock[:kind] == :message and Smalt.Amqp.LockManager.expired?(lock, now)
      end)
    end
  end

  # Re-put each tombstoned token row after the sweeps, bounded by the grace
  # window measured from FIRST sweep. Skipped when the grace is disabled (0)
  # or the row reappeared (e.g. a live re-acquire reused the key — impossible
  # for uuid tokens, but defensive).
  defp reinsert_message_tombstones(doomed) do
    grace = grace_ms()

    if grace > 0 do
      ensure_tombstone_table()
      now = System.system_time(:millisecond)

      # GC tombstone bookkeeping for tokens no longer being swept.
      :ets.match_object(@tombstone_table, {:_, :_})
      |> Enum.each(fn {token, first_swept_at} ->
        doomed? = Enum.any?(doomed, fn {t, _} -> t == token end)

        if not doomed? and now - first_swept_at > grace do
          :ets.delete(@tombstone_table, token)
        end
      end)

      Enum.each(doomed, fn {token, lock} ->
        existing = :ets.lookup(@tombstone_table, token)

        first_swept_at =
          case existing do
            [{^token, t}] ->
              t

            [] ->
              if :ets.insert_new(@tombstone_table, {token, now}) do
                now
              else
                case :ets.lookup(@tombstone_table, token) do
                  [{^token, t}] -> t
                  [] -> now
                end
              end
          end

        cond do
          # Grace measured from FIRST sweep: past it, drop the bookkeeping and
          # leave the token row deleted (renew answers 404 for a long-dead
          # token). The existing-entry check stops this pass from re-registering
          # a fresh tombstone after its own GC — grace must be able to expire.
          existing != [] and now - first_swept_at > grace ->
            :ets.delete(@tombstone_table, token)
            :ok

          Smalt.Amqp.LockManager.get(token) == :error ->
            Smalt.Store.put(:smalt_sb_locks, token, lock)
        end
      end)
    end

    :ok
  end

  defp ensure_tombstone_table do
    if :ets.info(@tombstone_table) == :undefined do
      :ets.new(@tombstone_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  # -- GenServer ----------------------------------------------------------------

  @impl true
  def init(opts) do
    # SHIM-COURT R132: tick_ms is validated fail-closed at boot. A non-positive
    # tick would spin the sweep unthrottled (100% CPU); a negative tick reaches
    # Process.send_after and raises ArgumentError mid-run, crash-restarting in a
    # storm that exhausts the AmqpBroker restart intensity and kills the broker
    # tree. Better to refuse boot with a typed error than to run mis-throttled.
    # W1a exemplar (opts-fallback class): opts win, ontology default behind
    # the Smalt.Config projection (smalt:ck-amqp-sweeper-tick-ms).
    Process.set_label(%{service: :amqp, role: :sweeper})
    tick_ms = opts[:tick_ms] || Smalt.Config.amqp_sweeper_tick_ms()

    unless is_integer(tick_ms) and tick_ms > 0 do
      raise ArgumentError,
            "Smalt.Amqp.Sweeper tick_ms must be a positive integer, got: #{inspect(tick_ms)} " <>
              "(opts[:tick_ms] or Application.get_env(:smalt, :amqp_sweeper_tick_ms))"
    end

    Process.send_after(self(), :tick, 0)
    {:ok, %{tick_ms: tick_ms}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    run_pass()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_pass()
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end
end
