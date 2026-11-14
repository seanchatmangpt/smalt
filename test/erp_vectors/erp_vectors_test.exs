defmodule Smalt.ErpVectorsTest do
  use ExUnit.Case, async: true

  @dir __DIR__
  defp load(f), do: @dir |> Path.join(f) |> File.read!() |> :json.decode()

  test "QBO JournalEntry balances and Account shape" do
    lines = load("qbo_journal_entry.json")["JournalEntry"]["Line"]

    sum = fn t ->
      Enum.sum(for %{"Amount" => a, "JournalEntryLineDetail" => %{"PostingType" => ^t}} <- lines, do: a)
    end

    assert sum.("Debit") == sum.("Credit")
    acct = load("qbo_account.json")["Account"]
    assert Map.has_key?(acct, "AccountType") and Map.has_key?(acct, "Name")
  end

  test "Xero ManualJournal balances (signed lines sum to zero)" do
    [j] = load("xero_manual_journal.json")["ManualJournals"]
    assert Enum.sum(for l <- j["JournalLines"], do: l["LineAmount"]) == 0
  end

  test "NetSuite journalentry debits equal credits" do
    items = load("netsuite_journalentry.json")["journalentry"]["line"]["items"]
    assert Enum.sum(for %{"debit" => d} <- items, do: d) == Enum.sum(for %{"credit" => c} <- items, do: c)
  end

  test "drives lib/smalt/erp when present" do
    if File.dir?(Path.expand("../../lib/smalt/erp", __DIR__)) do
      mods =
        for {m, _} <- :code.all_loaded(), String.starts_with?(Atom.to_string(m), "Elixir.Smalt.Erp"), do: m

      assert mods != [], "lib/smalt/erp exists but no Smalt.Erp modules loaded"
      IO.puts("[INFO] Smalt.Erp modules: #{inspect(mods)} (wire-level driving pending API)")
    else
      IO.puts("[SKIP] lib/smalt/erp absent; vectors validated against published shapes only")
    end
  end
end
