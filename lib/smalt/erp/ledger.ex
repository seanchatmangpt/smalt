defmodule Smalt.Erp.Ledger do
  @moduledoc "Per-vendor chart of accounts + posted entries (Agent). Balances in integer cents."
  use Agent

  @coa [
    %{id: "1000", name: "Cash", type: :asset},
    %{id: "1200", name: "Accounts Receivable", type: :ar},
    %{id: "2000", name: "Accounts Payable", type: :ap},
    %{id: "3000", name: "Retained Earnings", type: :equity},
    %{id: "4000", name: "Revenue", type: :revenue},
    %{id: "5000", name: "Expenses", type: :expense}
  ]

  def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _ -> :ok
    end
  end

  def reset do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %{} end)
  end

  def accounts(_vendor), do: @coa

  def post(vendor, je) do
    ensure_started()
    ids = MapSet.new(@coa, & &1.id)

    case Enum.find(je.lines, &(&1.account not in ids)) do
      nil ->
        Agent.update(__MODULE__, &Map.update(&1, vendor, [je], fn l -> l ++ [je] end))
        :ok

      l ->
        {:error, {:unknown_account, l.account}}
    end
  end

  def entries(vendor) do
    ensure_started()
    Agent.get(__MODULE__, &Map.get(&1, vendor, []))
  end

  @doc "Trial balance rows [%{account, name, debit, credit}] with net side only."
  def trial_balance(vendor) do
    lines = entries(vendor) |> Enum.flat_map(& &1.lines)

    for a <- @coa do
      mine = Enum.filter(lines, &(&1.account == a.id))
      net = Enum.sum(Enum.map(mine, & &1.debit)) - Enum.sum(Enum.map(mine, & &1.credit))
      %{account: a.id, name: a.name, debit: max(net, 0), credit: max(-net, 0)}
    end
  end

  @doc "Aging buckets for :ar or :ap as of an ISO date."
  def aging(vendor, type, as_of) do
    acct = Enum.find(@coa, &(&1.type == type)).id
    {:ok, asof} = Date.from_iso8601(as_of)

    entries(vendor)
    |> Enum.flat_map(& &1.lines)
    |> Enum.filter(&(&1.account == acct))
    |> Enum.reduce(%{current: 0, d1_30: 0, d31_60: 0, d61_90: 0, d90_plus: 0}, fn l, acc ->
      amt = if type == :ar, do: l.debit - l.credit, else: l.credit - l.debit
      Map.update!(acc, bucket(l.due_date, asof), &(&1 + amt))
    end)
  end

  defp bucket(nil, _), do: :current

  defp bucket(due, asof) do
    case Date.from_iso8601(due) do
      {:ok, d} ->
        age = Date.diff(asof, d)

        cond do
          age <= 0 -> :current
          age <= 30 -> :d1_30
          age <= 60 -> :d31_60
          age <= 90 -> :d61_90
          true -> :d90_plus
        end

      _ ->
        :current
    end
  end
end
