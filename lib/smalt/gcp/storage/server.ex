defmodule Smalt.GCP.Storage.Server do
  @moduledoc """
  GenServer owning the GCS dialect state (`Smalt.GCP.Storage`). All mutation
  is serialized here, so ifGenerationMatch is a true atomic precondition.
  `call/2` applies `fun :: state -> {:ok, st, reply} | {:ok, st} | {:incomplete, st, n} | {:error, _}`.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts), do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  def call(server \\ __MODULE__, fun), do: GenServer.call(server, {:apply, fun})

  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(:ok), do: {:ok, Smalt.GCP.Storage.new()}

  @impl true
  def handle_call(:reset, _f, _s), do: {:reply, :ok, Smalt.GCP.Storage.new()}

  def handle_call({:apply, fun}, _from, st) do
    try do
      case fun.(st) do
        {:ok, st2, reply} -> {:reply, {:ok, reply}, st2}
        {:ok, st2} -> {:reply, :ok, st2}
        {:incomplete, st2, n} -> {:reply, {:incomplete, n}, st2}
        {:error, _} = e -> {:reply, e, st}
      end
    rescue
      e -> {:reply, {:error, %{status: 500, reason: "backendError", message: Exception.message(e)}}, st}
    end
  end
end
