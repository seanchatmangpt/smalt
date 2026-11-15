defmodule Smalt.H09.Journal do
  @moduledoc "ERP journal: balanced-entry validation, GL accounts, stateful posting, trial balance. Integer cents."
  alias Smalt.H09.{Vocab, State}

  def accounts, do: Vocab.gl_accounts()

  @doc "Validate body %{\"entry_id\", \"lines\" => [%{\"account\", \"debit_cents\"|\"credit_cents\"}]}."
  def validate(%{"lines" => lines} = b) when is_list(lines) and length(lines) >= 2 do
    ids = MapSet.new(accounts(), & &1.id)

    with {:ok, ls} <- norm(lines),
         nil <- Enum.find(ls, &(not MapSet.member?(ids, &1.account))) |> unknown(),
         d = ls |> Enum.map(& &1.debit) |> Enum.sum(),
         c = ls |> Enum.map(& &1.credit) |> Enum.sum(),
         true <- d == c or {:error, {Vocab.err(:unbalanced), %{debits: d, credits: c}}} do
      {:ok, %{entry_id: b["entry_id"], entity: b["entity"], lines: ls, debit_total_cents: d, credit_total_cents: c}}
    else
      {:error, _} = e -> e
    end
  end

  def validate(_), do: {:error, {Vocab.err(:invalid), [:lines]}}

  defp unknown(nil), do: nil
  defp unknown(l), do: {:error, {Vocab.err(:unknown_account), l.account}}

  defp norm(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn l, {:ok, acc} ->
      d = if is_map(l), do: Map.get(l, "debit_cents", 0), else: nil
      c = if is_map(l), do: Map.get(l, "credit_cents", 0), else: nil

      if is_binary(l["account"]) and is_integer(d) and is_integer(c) and d >= 0 and c >= 0 and (d > 0) != (c > 0) do
        {:cont, {:ok, acc ++ [%{account: l["account"], debit: d, credit: c, memo: l["memo"]}]}}
      else
        {:halt, {:error, {Vocab.err(:invalid), [:lines]}}}
      end
    end)
  end

  def post(%{"entity" => ent, "entry_id" => id} = b) when is_binary(ent) and is_binary(id) do
    with {:ok, je} <- validate(b) do
      State.update(fn s ->
        list = Map.get(s.journal, ent, [])

        if Enum.any?(list, &(&1.entry_id == id)) do
          {{:error, {Vocab.err(:duplicate), id}}, s}
        else
          {{:ok, %{je | entity: ent} |> Map.put(:seq, length(list) + 1)}, %{s | journal: Map.put(s.journal, ent, list ++ [Map.put(je, :seq, length(list) + 1)])}}
        end
      end)
    end
  end

  def post(_), do: {:error, {Vocab.err(:invalid), [:entity, :entry_id]}}

  @doc "Trial balance for one entity (or all when nil); totals must match."
  def trial_balance(entity) do
    lines =
      State.get(fn s ->
        case entity do
          nil -> s.journal |> Map.values() |> List.flatten()
          e -> Map.get(s.journal, e, [])
        end
      end)
      |> Enum.flat_map(& &1.lines)

    rows =
      for a <- accounts() do
        mine = Enum.filter(lines, &(&1.account == a.id))
        net = Enum.sum(Enum.map(mine, & &1.debit)) - Enum.sum(Enum.map(mine, & &1.credit))
        %{account: a.id, name: a.name, debit_cents: max(net, 0), credit_cents: max(-net, 0)}
      end

    d = rows |> Enum.map(& &1.debit_cents) |> Enum.sum()
    c = rows |> Enum.map(& &1.credit_cents) |> Enum.sum()
    %{rows: rows, debit_total_cents: d, credit_total_cents: c, balanced: d == c}
  end
end
