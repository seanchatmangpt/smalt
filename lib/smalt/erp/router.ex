defmodule Smalt.Erp.Router do
  @moduledoc "Wire twins: QBO, NetSuite SuiteTalk REST, Intacct REST, Xero. Vendor-shaped JSON."
  use Plug.Router
  alias Smalt.Erp.{Ledger, Journal, Money}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  # ---- QuickBooks Online
  get "/qbo/v3/company/:_realm/query" do
    json(conn, 200, %{"QueryResponse" => %{"Account" => Enum.map(Ledger.accounts(:qbo), &qbo_acct/1)}})
  end

  get "/qbo/v3/company/:_realm/reports/TrialBalance" do
    rows = for r <- Ledger.trial_balance(:qbo), do: [r.account, Money.fmt(r.debit), Money.fmt(r.credit)]
    json(conn, 200, %{"Header" => %{"ReportName" => "TrialBalance"}, "Rows" => %{"Row" => rows}})
  end

  get "/qbo/v3/company/:_realm/reports/AgedReceivables" do
    json(conn, 200, %{"Header" => %{"ReportName" => "AgedReceivables"}, "Aging" => aging(:qbo, :ar, conn)})
  end

  get "/qbo/v3/company/:_realm/reports/AgedPayables" do
    json(conn, 200, %{"Header" => %{"ReportName" => "AgedPayables"}, "Aging" => aging(:qbo, :ap, conn)})
  end

  post "/qbo/v3/company/:_realm/journalentry" do
    imp(conn, :qbo, fn je -> %{"JournalEntry" => %{"Id" => id(je), "Line" => length(je.lines)}} end)
  end

  # ---- NetSuite SuiteTalk REST
  get "/netsuite/services/rest/record/v1/account" do
    items = for a <- Ledger.accounts(:netsuite), do: %{"id" => a.id, "acctName" => a.name, "acctType" => to_string(a.type)}
    json(conn, 200, %{"count" => length(items), "items" => items, "hasMore" => false})
  end

  get "/netsuite/services/rest/query/v1/trialBalance" do
    items = for r <- Ledger.trial_balance(:netsuite), do: %{"account" => r.account, "debit" => Money.fmt(r.debit), "credit" => Money.fmt(r.credit)}
    json(conn, 200, %{"items" => items})
  end

  get "/netsuite/services/rest/query/v1/arAging" do
    json(conn, 200, %{"items" => [aging(:netsuite, :ar, conn)]})
  end

  get "/netsuite/services/rest/query/v1/apAging" do
    json(conn, 200, %{"items" => [aging(:netsuite, :ap, conn)]})
  end

  post "/netsuite/services/rest/record/v1/journalEntry" do
    imp(conn, :netsuite, fn je -> %{"id" => id(je)} end)
  end

  # ---- Intacct
  get "/intacct/ia/api/v1/objects/general-ledger/account" do
    json(conn, 200, %{"ia::result" => for(a <- Ledger.accounts(:intacct), do: %{"id" => a.id, "name" => a.name})})
  end

  get "/intacct/ia/api/v1/objects/general-ledger/trial-balance" do
    json(conn, 200, %{"ia::result" => for(r <- Ledger.trial_balance(:intacct), do: %{"account" => r.account, "debit" => Money.fmt(r.debit), "credit" => Money.fmt(r.credit)})})
  end

  get "/intacct/ia/api/v1/objects/accounts-receivable/aging" do
    json(conn, 200, %{"ia::result" => aging(:intacct, :ar, conn)})
  end

  get "/intacct/ia/api/v1/objects/accounts-payable/aging" do
    json(conn, 200, %{"ia::result" => aging(:intacct, :ap, conn)})
  end

  post "/intacct/ia/api/v1/objects/general-ledger/journal-entry" do
    imp(conn, :intacct, fn je -> %{"ia::result" => %{"key" => id(je)}} end)
  end

  # ---- Xero
  get "/xero/api.xro/2.0/Accounts" do
    json(conn, 200, %{"Accounts" => for(a <- Ledger.accounts(:xero), do: %{"Code" => a.id, "Name" => a.name})})
  end

  get "/xero/api.xro/2.0/Reports/TrialBalance" do
    rows = for r <- Ledger.trial_balance(:xero), do: %{"Account" => r.account, "Debit" => Money.fmt(r.debit), "Credit" => Money.fmt(r.credit)}
    json(conn, 200, %{"Reports" => [%{"ReportName" => "Trial Balance", "Rows" => rows}]})
  end

  get "/xero/api.xro/2.0/Reports/AgedReceivablesByContact" do
    json(conn, 200, %{"Reports" => [%{"Aging" => aging(:xero, :ar, conn)}]})
  end

  get "/xero/api.xro/2.0/Reports/AgedPayablesByContact" do
    json(conn, 200, %{"Reports" => [%{"Aging" => aging(:xero, :ap, conn)}]})
  end

  post "/xero/api.xro/2.0/ManualJournals" do
    imp(conn, :xero, fn je -> %{"ManualJournals" => [%{"ManualJournalID" => id(je)}]} end)
  end

  match _ do
    json(conn, 404, %{"error" => "not_found"})
  end

  defp imp(conn, vendor, ok) do
    case Journal.import_entry(vendor, conn.body_params) do
      {:ok, je} -> json(conn, 200, ok.(je))
      {:error, {:unbalanced, d, c}} -> json(conn, 400, %{"error" => "unbalanced", "debits" => d, "credits" => c})
      {:error, {:unknown_account, a}} -> json(conn, 400, %{"error" => "unknown_account", "account" => a})
      {:error, e} -> json(conn, 400, %{"error" => inspect(e)})
    end
  end

  defp aging(vendor, type, conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    a = Ledger.aging(vendor, type, conn.query_params["asOf"] || Date.to_iso8601(Date.utc_today()))
    Map.new(a, fn {k, v} -> {to_string(k), Money.fmt(v)} end)
  end

  defp qbo_acct(a), do: %{"Id" => a.id, "Name" => a.name, "AccountType" => to_string(a.type)}
  defp id(je), do: Integer.to_string(:erlang.phash2({je, System.unique_integer()}))

  defp json(conn, status, body) do
    conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
