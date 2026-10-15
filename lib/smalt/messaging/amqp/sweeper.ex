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

  @tick_key {__MODULE__, :tick_ms}
  @default_tick_ms 250

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
    Smalt.Amqp.LockManager.sweep()
    if GenServer.whereis(Smalt.Amqp.CbsRouter) do
      Smalt.Amqp.CbsRouter.gc()
    end
    Smalt.Messaging.EventHubs.sweep()
    :ok
  end

  # -- GenServer ----------------------------------------------------------------

  @impl true
  def init(opts) do
    tick_ms = opts[:tick_ms] || Application.get_env(:smalt, :amqp_sweeper_tick_ms, @default_tick_ms)
    :persistent_term.put(@tick_key, tick_ms)
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
