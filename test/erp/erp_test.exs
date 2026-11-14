defmodule Smalt.ErpTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias Smalt.Erp.{Router, Ledger, Money}

  setup do
    Ledger.reset()
    :ok
  end

  defp post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  defp get(path), do: conn(:get, path) |> Router.call(Router.init([]))

  @qbo "/qbo/v3/company/1/journalentry"
  defp qbo(d, c) do
    %{"TxnDate" => "2026-01-01", "Line" => [
      %{"Amount" => d, "DueDate" => "2026-01-01", "JournalEntryLineDetail" => %{"PostingType" => "Debit", "AccountRef" => %{"value" => "1200"}}},
      %{"Amount" => c, "JournalEntryLineDetail" => %{"PostingType" => "Credit", "AccountRef" => %{"value" => "4000"}}}]}
  end

  test "money parses to integer cents without float drift" do
    assert {:ok, 1010} = Money.to_cents(10.1)
    assert {:ok, 1} = Money.to_cents("0.01")
    assert {:error, :bad_amount} = Money.to_cents("1e3")
  end

  test "QBO balanced import lands in trial balance; unbalanced refused" do
    assert post(@qbo, qbo(100.10, "100.10")).status == 200
    bad = post(@qbo, qbo(100, 99.99))
    assert bad.status == 400
    assert %{"error" => "unbalanced", "debits" => 10000, "credits" => 9999} = Jason.decode!(bad.resp_body)

    tb = Ledger.trial_balance(:qbo)
    assert Enum.sum(Enum.map(tb, & &1.debit)) == Enum.sum(Enum.map(tb, & &1.credit))
    assert Enum.find(tb, &(&1.account == "1200")).debit == 10010
    assert length(Ledger.entries(:qbo)) == 1
  end

  test "AR aging buckets by due date" do
    post(@qbo, qbo(50, 50))
    r = get("/qbo/v3/company/1/reports/AgedReceivables?asOf=2026-03-10")
    assert %{"Aging" => %{"d61_90" => "50.00", "current" => "0.00"}} = Jason.decode!(r.resp_body)
  end

  test "NetSuite, Intacct, Xero import and normalize identically" do
    ns = %{"tranDate" => "2026-01-01", "line" => %{"items" => [
      %{"account" => %{"id" => "1000"}, "debit" => 5}, %{"account" => %{"id" => "4000"}, "credit" => 5}]}}
    ia = %{"postingDate" => "2026-01-01", "lines" => [
      %{"glAccount" => "1000", "txnType" => "debit", "txnAmount" => "5.00"},
      %{"glAccount" => "4000", "txnType" => "credit", "txnAmount" => "5.00"}]}
    xe = %{"Date" => "2026-01-01", "JournalLines" => [
      %{"AccountCode" => "1000", "LineAmount" => 5}, %{"AccountCode" => "4000", "LineAmount" => -5}]}

    assert post("/netsuite/services/rest/record/v1/journalEntry", ns).status == 200
    assert post("/intacct/ia/api/v1/objects/general-ledger/journal-entry", ia).status == 200
    assert post("/xero/api.xro/2.0/ManualJournals", xe).status == 200

    lines = for v <- [:netsuite, :intacct, :xero], do: Ledger.entries(v) |> hd() |> Map.get(:lines) |> Enum.map(&Map.delete(&1, :due_date))
    assert [l, l, l] = lines
    assert get("/xero/api.xro/2.0/Reports/TrialBalance").status == 200
    assert get("/netsuite/services/rest/record/v1/account").status == 200
  end

  test "unknown account refused" do
    xe = %{"JournalLines" => [%{"AccountCode" => "9", "LineAmount" => 1}, %{"AccountCode" => "1000", "LineAmount" => -1}]}
    assert post("/xero/api.xro/2.0/ManualJournals", xe).status == 400
  end
end
