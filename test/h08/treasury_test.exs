defmodule Smalt.H08.TreasuryTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Smalt.Treasury.Router
  alias Smalt.Treasury.Iso20022

  defp call(method, path, body, ctype \\ "application/json") do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    conn =
      conn(method, path, raw)
      |> put_req_header("content-type", ctype)
      |> Router.call(Router.init([]))

    conn
  end

  defp jpost(path, body) do
    c = call(:post, path, body)
    {c.status, Jason.decode!(c.resp_body)}
  end

  defp uid(p), do: p <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp open!(id, cents) do
    assert {201, _} = jpost("/h08/accounts", %{"account_id" => id, "account" => "AC" <> id, "routing" => "091000019", "opening_cents" => cents})
  end

  defp card!(card, acct, extra \\ %{}) do
    body = Map.merge(%{"card_token" => card, "mccs" => ["5411"], "max_amount_cents" => 200_000, "countries" => ["USA"], "account_id" => acct}, extra)
    assert {201, _} = jpost("/h08/cards", body)
  end

  defp auth(token, card, amount, extra \\ %{}) do
    Map.merge(%{"token" => token, "card_token" => card, "amount" => amount, "created" => "2026-11-14T10:00:00Z",
                "merchant" => %{"mcc" => "5411", "country" => "USA", "descriptor" => "GROCER"}}, extra)
  end

  test "asa: insufficient funds declines, approval holds, replay does not double-hold, clearing books" do
    a = uid("asa")
    c = uid("card")
    open!(a, 100_000)
    card!(c, a)

    t1 = uid("t")
    assert {200, %{"result" => "APPROVE", "available_cents" => 40_000}} = jpost("/lithic/asa", auth(t1, c, 60_000))
    assert {200, %{"result" => "INSUFFICIENT_FUNDS", "reasons" => ["INSUFFICIENT_FUNDS"]}} = jpost("/lithic/asa", auth(uid("t"), c, 50_000))
    assert {200, %{"result" => "APPROVE"}} = jpost("/lithic/asa", auth(t1, c, 60_000))
    assert Smalt.H08.Ledger.account(a).available_cents == 40_000
    assert Smalt.H08.Ledger.account(a).current_cents == 100_000

    # pending shows in Plaid transactions before clearing
    {200, %{"transactions" => [p]}} =
      jpost("/plaid/transactions/get", %{"access_token" => a, "start_date" => "2026-11-01", "end_date" => "2026-11-30"})

    assert p["pending"] == true and p["amount"] == 600.0

    assert {200, %{"state" => "CLEARED", "amount" => 60_000}} =
             jpost("/lithic/asa/clearing", %{"token" => t1, "booked" => "2026-11-14"})

    acct = Smalt.H08.Ledger.account(a)
    assert {acct.available_cents, acct.current_cents} == {40_000, 40_000}

    {200, %{"transactions" => [x], "total_transactions" => 1}} =
      jpost("/plaid/transactions/get", %{"access_token" => a, "start_date" => "2026-11-01", "end_date" => "2026-11-30"})

    assert x["pending"] == false and x["amount"] == 600.0 and x["name"] == "GROCER"
    assert {409, _} = jpost("/lithic/asa/clearing", %{"token" => t1, "booked" => "2026-11-14"})
  end

  test "asa: void releases hold; paused and merchant declines" do
    a = uid("asa")
    c = uid("card")
    open!(a, 10_000)
    card!(c, a)
    t = uid("t")
    assert {200, %{"result" => "APPROVE"}} = jpost("/lithic/asa", auth(t, c, 10_000))
    assert Smalt.H08.Ledger.account(a).available_cents == 0
    assert {200, %{"state" => "VOIDED"}} = jpost("/lithic/asa/void", %{"token" => t})
    assert Smalt.H08.Ledger.account(a).available_cents == 10_000

    assert {200, %{"result" => "UNAUTHORIZED_MERCHANT", "reasons" => ["MCC_MISMATCH", "GEO_MISMATCH"]}} =
             jpost("/lithic/asa", auth(uid("t"), c, 100, %{"merchant" => %{"mcc" => "7995", "country" => "FRA"}}))

    assert {200, %{"state" => "PAUSED"}} = jpost("/h08/cards/#{c}/state", %{"state" => "PAUSED"})
    assert {200, %{"result" => "CARD_PAUSED"}} = jpost("/lithic/asa", auth(uid("t"), c, 100))
    assert {200, %{"result" => "CARD_CLOSED"}} = jpost("/lithic/asa", auth(uid("t"), "nope", 100))
    assert {422, %{"type" => "invalid_request"}} = jpost("/lithic/asa", %{"token" => "x"})
  end

  test "plaid transactions: typed errors in Plaid shape" do
    assert {400, %{"error_type" => "ITEM_ERROR", "error_code" => "INVALID_ACCESS_TOKEN"}} =
             jpost("/plaid/transactions/get", %{"access_token" => "none", "start_date" => "2026-11-01", "end_date" => "2026-11-30"})

    a = uid("pl")
    open!(a, 5)
    assert {400, %{"error_code" => "MISSING_FIELDS"}} = jpost("/plaid/transactions/get", %{"access_token" => a})
    assert {400, %{"error_code" => "INVALID_FIELD"}} = jpost("/plaid/transactions/get", %{"access_token" => a, "start_date" => "2026-12-01", "end_date" => "2026-11-01"})
  end

  test "pain.001 executes against ledger; AM04 on insufficient funds; camt.053/054 reflect state" do
    d = uid("dbtr")
    k = uid("cdtr")
    open!(d, 50_000)
    open!(k, 0)
    msg = uid("MSG")

    {200, xml} =
      {200,
       call(:post, "/h08/iso20022/pain001/build",
         %{"msg_id" => msg, "created_at" => "2026-11-14T09:00:00", "exec_date" => "2026-11-14", "initiator" => "ACME",
           "debtor" => %{"name" => "ACME", "account" => d, "routing" => "091000019"},
           "payments" => [
             %{"end_to_end_id" => "E1", "amount_cents" => 30_000, "creditor" => %{"name" => "VEND", "account" => k, "routing" => "021000021"}},
             %{"end_to_end_id" => "E2", "amount_cents" => 30_000, "creditor" => %{"name" => "VEND", "account" => k, "routing" => "021000021"}}
           ]}).resp_body}

    assert xml =~ "pain.001.001.09" and xml =~ "<NbOfTxs>2</NbOfTxs>" and xml =~ "<CtrlSum>600.00</CtrlSum>"

    c = call(:post, "/h08/iso20022/pain001", xml, "application/xml")
    assert c.status == 200
    r = Jason.decode!(c.resp_body)
    assert r["group_status"] == "PART" and r["accepted"] == 1 and r["rejected"] == 1
    assert [%{"status" => "ACSC"}, %{"status" => "RJCT", "reason" => "AM04"}] = r["transactions"]
    assert Smalt.H08.Ledger.account(d).current_cents == 20_000
    assert Smalt.H08.Ledger.account(k).current_cents == 30_000

    # replay of the same MsgId is rejected as a duplicate with no further posting
    r2 = call(:post, "/h08/iso20022/pain001", xml, "application/xml").resp_body |> Jason.decode!()
    assert r2["group_status"] == "RJCT" and r2["group_reason"] == "DUPL"
    assert Smalt.H08.Ledger.account(d).current_cents == 20_000

    s = call(:get, "/h08/iso20022/camt053/#{d}", "")
    assert s.status == 200 and s.resp_body =~ "camt.053.001.08"
    assert s.resp_body =~ "<Cd>OPBD</Cd></CdOrPrtry></Tp><Amt Ccy=\"USD\">500.00"
    assert s.resp_body =~ "<Cd>CLBD</Cd></CdOrPrtry></Tp><Amt Ccy=\"USD\">200.00"
    assert {:ok, %{entries: [%{amount_cents: 30_000, direction: :debit, end_to_end_id: "E1"}]}} = Iso20022.parse_camt053(s.resp_body)

    n0 = call(:get, "/h08/iso20022/camt054/#{k}?since_seq=0", "").resp_body
    assert n0 =~ "camt.054.001.08" and n0 =~ "<CdtDbtInd>CRDT</CdtDbtInd>" and n0 =~ "300.00"
    n1 = call(:get, "/h08/iso20022/camt054/#{k}?since_seq=1", "").resp_body
    refute n1 =~ "<Ntry>"
    assert call(:get, "/h08/iso20022/camt053/missing", "").status == 404
  end

  test "pain.001 header mismatch rejects whole file; malformed is 422" do
    d = uid("dbtr")
    open!(d, 1000)
    xml = Smalt.H08.Pain001.build(%{msg_id: uid("M"), created_at: "2026-11-14T09:00:00", exec_date: "2026-11-14", initiator: "X",
      debtor: %{name: "X", account: d, routing: "091000019"},
      payments: [%{end_to_end_id: "E", amount_cents: 100, creditor: %{name: "Y", account: "ext", routing: "021000021"}}]})

    bad = String.replace(xml, "<NbOfTxs>1</NbOfTxs>", "<NbOfTxs>2</NbOfTxs>")
    r = call(:post, "/h08/iso20022/pain001", bad, "application/xml").resp_body |> Jason.decode!()
    assert r["group_status"] == "RJCT" and r["group_reason"] == "FF01"
    assert Smalt.H08.Ledger.account(d).current_cents == 1000
    assert call(:post, "/h08/iso20022/pain001", "<x/>", "application/xml").status == 422
  end

  @file_body %{
    "immediate_destination" => "091000019", "immediate_origin" => "021000021", "destination_name" => "Dest Bank",
    "origin_name" => "Origin Bank", "file_date" => "2026-11-14", "file_time" => "1230",
    "batches" => [
      %{"service_class" => "200", "company_name" => "Acme", "company_id" => "1234567890", "sec" => "PPD",
        "entry_description" => "PAYROLL", "effective_date" => "2026-11-16", "odfi" => "02100002",
        "entries" => [
          %{"transaction_code" => "22", "rdfi_routing" => "091000019", "account" => "111", "amount_cents" => 12_345, "individual_name" => "A"},
          %{"transaction_code" => "27", "rdfi_routing" => "021000021", "account" => "222", "amount_cents" => 2_000, "individual_name" => "B"}
        ]}
    ]
  }

  test "nacha: build is 94-wide, block-padded, totals computed; validate round-trips and catches tamper" do
    c = call(:post, "/h08/nacha/file", @file_body)
    assert c.status == 200
    lines = String.split(c.resp_body, "\n", trim: true)
    assert Enum.all?(lines, &(String.length(&1) == 94))
    assert length(lines) == 10
    assert String.starts_with?(Enum.at(lines, 0), "101 091000019 021000021")
    [_, _, e1, e2, bc, fc | pad] = lines
    assert String.slice(e1, 29, 10) == "0000012345"
    assert String.slice(bc, 20, 12) == "000000002000" and String.slice(bc, 32, 12) == "000000012345"
    assert String.slice(fc, 13, 8) == "00000002"
    assert Enum.all?(pad, &(&1 == String.duplicate("9", 94)))
    assert String.slice(e2, 1, 2) == "27"

    v = call(:post, "/h08/nacha/validate", c.resp_body, "text/plain")
    assert %{"valid" => true, "batches" => 1, "entries" => 2} = Jason.decode!(v.resp_body)

    tampered = String.replace(c.resp_body, "0000012345", "0000012346", global: false)
    t = Jason.decode!(call(:post, "/h08/nacha/validate", tampered, "text/plain").resp_body)
    assert t["valid"] == false and "BATCH_CREDIT_TOTAL_MISMATCH" in t["issues"]
  end

  test "nacha: bad routing check digit and service class mismatch refused" do
    b = put_in(@file_body, ["batches", Access.at(0), "entries", Access.at(0), "rdfi_routing"], "091000018")
    b = put_in(b, ["batches", Access.at(0), "service_class"], "220")
    c = call(:post, "/h08/nacha/file", b)
    assert c.status == 422
    issues = Jason.decode!(c.resp_body)["issues"]
    assert "BATCH1_ENTRY1_BAD_ROUTING" in issues and "BATCH1_SERVICE_CLASS_MISMATCH" in issues
  end
end
