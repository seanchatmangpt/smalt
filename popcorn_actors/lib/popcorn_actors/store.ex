defmodule PopcornActors.Store do
  @moduledoc """
  Pure-decision store actor: an in-memory kv echo with no OTP apps beyond
  kernel/stdlib/popcorn. On the browser VM, messages can be bridged to JS via
  Popcorn.JS; host-side (mix test / mix run) it is just a plain GenServer.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.get(opts, :initial, %{}),
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @impl true
  def init(initial) do
    {:ok, %{state: initial}}
  end

  @doc "Echo API: store `key` and return the echoed payload (host + browser)."
  @spec echo(term(), term()) :: :ok
  def echo(key, value) do
    GenServer.cast(__MODULE__, {:echo, key, value})
  end

  @impl true
  def handle_cast({:echo, key, value}, s) do
    {:noreply, %{s | state: Map.put(s.state, key, value)}}
  end
end
