defmodule Smalt.Erp.Journal do
  @moduledoc """
  Normalizes vendor journal-entry payloads (QBO, NetSuite, Intacct, Xero) to
  `%{memo, date, lines: [%{account, debit, credit, due_date}]}` (integer cents)
  and imports them, asserting debits == credits.
  """
  alias Smalt.Erp.Money

  @spec normalize(atom(), map()) :: {:ok, map()} | {:error, term()}
  def normalize(:qbo, %{"Line" => lines} = b) when is_list(lines) do
    lines
    |> Enum.map(fn l ->
      d = l["JournalEntryLineDetail"] || %{}
      acct = get_in(d, ["AccountRef", "value"])
      amt = l["Amount"]

      case d["PostingType"] do
        "Debit" -> mk(acct, amt, nil, l["DueDate"])
        "Credit" -> mk(acct, nil, amt, l["DueDate"])
        _ -> {:error, :bad_posting_type}
      end
    end)
    |> wrap(b["TxnDate"], b["PrivateNote"])
  end

  def normalize(:netsuite, %{"line" => %{"items" => items}} = b) when is_list(items) do
    items
    |> Enum.map(fn l -> mk(get_in(l, ["account", "id"]), l["debit"], l["credit"], l["dueDate"]) end)
    |> wrap(b["tranDate"], b["memo"])
  end

  def normalize(:intacct, %{"lines" => lines} = b) when is_list(lines) do
    lines
    |> Enum.map(fn l ->
      amt = l["txnAmount"]

      case l["txnType"] do
        "debit" -> mk(l["glAccount"], amt, nil, l["dueDate"])
        "credit" -> mk(l["glAccount"], nil, amt, l["dueDate"])
        _ -> {:error, :bad_posting_type}
      end
    end)
    |> wrap(b["postingDate"], b["description"])
  end

  def normalize(:xero, %{"JournalLines" => lines} = b) when is_list(lines) do
    lines
    |> Enum.map(fn l ->
      # Xero: positive LineAmount = debit, negative = credit.
      case Money.to_cents(l["LineAmount"]) do
        {:ok, c} when c >= 0 -> mk(l["AccountCode"], Money.fmt(c), nil, l["DueDate"])
        {:ok, c} -> mk(l["AccountCode"], nil, Money.fmt(-c), l["DueDate"])
        e -> e
      end
    end)
    |> wrap(b["Date"], b["Narration"])
  end

  def normalize(_, _), do: {:error, :malformed_journal}

  defp mk(acct, d, c, due) do
    with true <- (is_binary(acct) and acct != "") or {:error, :missing_account},
         {:ok, dc} <- Money.to_cents(d),
         {:ok, cc} <- Money.to_cents(c),
         true <- (dc >= 0 and cc >= 0 and (dc == 0 or cc == 0)) or {:error, :bad_line} do
      {:ok, %{account: acct, debit: dc, credit: cc, due_date: due}}
    end
  end

  defp wrap(results, date, memo) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil when results == [] -> {:error, :no_lines}
      nil -> {:ok, %{date: date, memo: memo, lines: Enum.map(results, fn {:ok, l} -> l end)}}
      {:error, _} = e -> e
    end
  end

  @spec balanced?(map()) :: boolean()
  def balanced?(%{lines: ls}),
    do: Enum.sum(Enum.map(ls, & &1.debit)) == Enum.sum(Enum.map(ls, & &1.credit))

  @doc "Import: refuses unbalanced entries and unknown accounts; returns the posted entry."
  @spec import_entry(atom(), map()) :: {:ok, map()} | {:error, term()}
  def import_entry(vendor, body) do
    with {:ok, je} <- normalize(vendor, body),
         :ok <- check_balance(je),
         :ok <- Smalt.Erp.Ledger.post(vendor, je) do
      {:ok, je}
    end
  end

  defp check_balance(je) do
    d = Enum.sum(Enum.map(je.lines, & &1.debit))
    c = Enum.sum(Enum.map(je.lines, & &1.credit))
    if d == c, do: :ok, else: {:error, {:unbalanced, d, c}}
  end
end
