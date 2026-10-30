defmodule Smalt.Posh.Ingress.RingBuffer do
  @moduledoc """
  Bounded ingress ring buffer (Port In, POSH-002).

  v1 is a BEAM-native bounded queue (GenServer holding a `:queue`); the
  zero-allocation kernel ring is Phase 4 Rust scope and is NOT implemented
  here. On overflow the oldest item is dropped (drop-count telemetry on
  overflow); `drops/1` reads the cumulative counter. Push always promptly
  replies; callers are never blocked indefinitely.
  """

  use GenServer

  @drop_event [:smalt, :posh, :ingress, :drop]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Push. On overflow drops the oldest item and counts the drop."
  @spec push(GenServer.server(), term()) :: :ok
  def push(server, item) do
    GenServer.call(server, {:push, item})
  end

  @doc "Pops the oldest item; `:empty` when the buffer has nothing."
  @spec pop(GenServer.server()) :: {:ok, term()} | :empty
  def pop(server) do
    GenServer.call(server, :pop)
  end

  @doc "Cumulative drops since start."
  @spec drops(GenServer.server()) :: non_neg_integer()
  def drops(server) do
    GenServer.call(server, :drops)
  end

  @doc "Current buffered size."
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server) do
    GenServer.call(server, :size)
  end

  @impl true
  def init(opts) do
    {:ok, %{queue: :queue.new(), cap: Keyword.fetch!(opts, :capacity), drops: 0}}
  end

  @impl true
  def handle_call({:push, item}, _from, state) do
    {queue, n_dropped} =
      if :queue.len(state.queue) >= state.cap do
        {_, q} = :queue.out(state.queue)
        {q, 1}
      else
        {state.queue, 0}
      end

    if n_dropped == 1, do: :telemetry.execute(@drop_event, %{count: 1}, %{})

    {:reply, :ok, %{
      state
      | queue: :queue.in(item, queue),
        drops: state.drops + n_dropped
    }}
  end

  def handle_call(:pop, _from, state) do
    case :queue.out(state.queue) do
      {{:value, item}, q} -> {:reply, {:ok, item}, %{state | queue: q}}
      {:empty, q} -> {:reply, :empty, %{state | queue: q}}
    end
  end

  def handle_call(:drops, _from, state), do: {:reply, state.drops, state}

  def handle_call(:size, _from, state), do: {:reply, :queue.len(state.queue), state}
end
