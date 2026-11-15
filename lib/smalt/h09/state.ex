defmodule Smalt.H09.State do
  @moduledoc "Single Agent holding H09 stateful planes: journals, AR/AP, filings."
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case Agent.start(fn -> fresh() end, name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end

  def fresh, do: %{journal: %{}, arap: %{}, filings: %{}, version: 0}

  def reset do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> fresh() end)
  end

  def get(fun) do
    ensure_started()
    Agent.get(__MODULE__, fun)
  end

  def update(fun) do
    ensure_started()
    Agent.get_and_update(__MODULE__, fun)
  end
end
