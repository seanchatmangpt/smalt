defmodule Smalt.TreasuryTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.Treasury.{Asa, Iso20022, Router}

  defp post_json(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  @party %{"name" => "A", "account" => "1", "routing" => "021000021"}

  test "ETS table survives the request process that first touched it" do
    Task.async(fn -> Router.put_account("acct_survive", %{account_id: "x"}) end) |> Task.await()
    assert [{_, %{account_id: "x"}}] = :ets.lookup(:smalt_treasury, {:account, "acct_survive"})
  end

  test "pacs008 rejects nil/float/negative amounts with 422" do
    for amt <- [nil, 1.5, -5, 0] do
      c = post_json("/iso20022/pacs008", %{"amount" => amt, "debtor" => @party, "creditor" => @party})
      assert c.status == 422
    end
  end

  test "pacs008 refuses missing debtor/creditor fields" do
    c = post_json("/iso20022/pacs008", %{"amount" => 100, "debtor" => %{"name" => "A"}, "creditor" => @party})
    assert c.status == 422
    c = post_json("/iso20022/pacs008", %{"amount" => 100, "debtor" => @party})
    assert c.status == 422
    c = post_json("/iso20022/pacs008", %{"amount" => 100, "debtor" => @party, "creditor" => @party})
    assert c.status == 200
  end

  test "pacs008 escapes on build and unescapes on parse" do
    p = %{msg_id: "m", created_at: "t", end_to_end_id: "e", amount_cents: 1234,
          debtor: %{name: "A & B <\"x\"> 'q'", account: "1", routing: "r1"},
          creditor: %{name: "C", account: "2", routing: "r2"}}

    xml = Iso20022.pacs008(p)
    assert xml =~ "A &amp; B &lt;&quot;x&quot;&gt; &apos;q&apos;"
    assert {:ok, %{debtor_name: "A & B <\"x\"> 'q'", amount_cents: 1234}} = Iso20022.parse_pacs008(xml)
  end

  test "camt053 malformed entry returns error, not MatchError" do
    assert {:error, _} = Iso20022.parse_camt053("<Ntry><Amt Ccy=\"USD\">bad</Amt></Ntry>")
    assert {:ok, %{entries: []}} = Iso20022.parse_camt053("<x/>")
  end

  test "ACH same_day only when strictly true" do
    Router.put_account("ba1", %{account_id: "ba1"})

    for {v, expect} <- [{true, true}, {"false", false}, {"yes", false}, {1, false}] do
      c = post_json("/transfers/ach", %{"amount" => 100, "bank_account_id" => "ba1", "same_day" => v})
      assert c.status == 201
      assert Jason.decode!(c.resp_body)["same_day"] == expect
    end
  end

  test "Plaid balances are decimal strings, no float division" do
    Router.put_account("tok1", %{account_id: "a", account: "1", routing: "2", available_cents: 12345, current_cents: 5})
    c = post_json("/plaid/accounts/balance/get", %{"access_token" => "tok1"})
    [%{"balances" => b}] = Jason.decode!(c.resp_body)["accounts"]
    assert b["available"] == "123.45"
    assert b["current"] == "0.05"
  end

  test "ASA declines a non-map merchant instead of crashing" do
    rule = %{mccs: ["5411"], max_amount_cents: 1000, countries: ["US"]}
    for m <- [nil, "shop", 5, ["US"]] do
      d = Asa.decide(%{"token" => "t", "mcc" => "5411", "amount" => 100, "merchant" => m}, rule)
      assert d["result"] == "DECLINED"
      assert "GEO_MISMATCH" in d["reasons"]
    end
  end
end
