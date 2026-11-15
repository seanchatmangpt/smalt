defmodule Smalt.H09.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.H09.{Router, State, Ofac, Fire}

  setup do
    State.reset()
    :ok
  end

  defp call(method, path, body \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    c = Router.call(conn, Router.init([]))
    {c.status, Jason.decode!(c.resp_body)}
  end

  test "ofac: exact, alias, fuzzy hit; unrelated clear; scores deterministic integers" do
    {200, r} = call(:post, "/ofac/screen", %{"name" => "Northern Star Maritime Co"})
    assert [%{"id" => "FX-1001", "score_bps" => 10_000} | _] = r["hits"]
    {200, r} = call(:post, "/ofac/screen", %{"name" => "Orkid Trading Co."})
    assert Enum.any?(r["hits"], &(&1["id"] == "FX-1005"))
    {200, r} = call(:post, "/ofac/screen", %{"name" => "Maritime Northern Star Co"})
    assert hd(r["hits"])["id"] == "FX-1001"
    {200, r} = call(:post, "/ofac/screen", %{"name" => "Quiet Valley Bakery"})
    assert r == %{"status" => "clear", "hits" => []}
    {400, e} = call(:post, "/ofac/screen", %{"name" => ""})
    assert e["error"] == "invalid_request"
  end

  test "jaro-winkler reference values" do
    assert_in_delta Ofac.jw("MARTHA", "MARHTA"), 0.9611, 0.0001
    assert_in_delta Ofac.jaro("DIXON", "DICKSONX"), 0.7667, 0.0001
    assert Ofac.jw("ABC", "XYZ") == 0.0
  end

  test "fire: 750-byte records, round trip, control totals" do
    body = %{
      "year" => 2026, "transmitter_tin" => "123456789", "transmitter_control" => "AB123",
      "payer" => %{"tin" => "987654321", "name" => "Fixture Payer Inc"},
      "payees" => [
        %{"tin" => "111223333", "name" => "Alpha Contractor", "nonemployee_comp_cents" => 150_000_00, "federal_withheld_cents" => 100_00},
        %{"tin" => "222334444", "name" => "Beta Services", "nonemployee_comp_cents" => 75_000_50}
      ]
    }

    {200, r} = call(:post, "/fire/1099", body)
    assert r["record_length"] == 750 and r["record_count"] == 6 and r["payee_count"] == 2
    assert Enum.all?(r["records"], &(byte_size(&1) == 750))
    assert r["control_total_amount1_cents"] == 15_000_000 + 7_500_050
    assert r["control_total_amount4_cents"] == 10_000
    b = r["records"] |> Enum.at(2) |> Fire.parse_b()
    assert b.tin == "111223333" and b.amount1_cents == 15_000_000 and b.amount4_cents == 10_000
    assert b.name == "Alpha Contractor" and b.sequence == 3
    {400, e} = call(:post, "/fire/1099", put_in(body, ["payer", "tin"], "12"))
    assert e["error"] == "invalid_request"
  end

  test "iris: stateful duplicate detection and retrieval" do
    s = %{"year" => 2026, "form" => "1099-NEC", "payer_tin" => "987654321", "payee_tin" => "111223333", "amount_cents" => 70_000_00}
    {201, r} = call(:post, "/iris/submissions", s)
    assert r["status"] == "ACCEPTED"
    {200, g} = call(:get, "/iris/submissions/" <> r["id"])
    assert g["amount_cents"] == 70_000_00
    {409, e} = call(:post, "/iris/submissions", s)
    assert e["error"] == "duplicate_entry"
    {404, _} = call(:get, "/iris/submissions/nope")
  end

  test "sales tax: half-up rounding, discount, weekend roll of due date" do
    b = %{"state" => "TX", "period" => "2026-10", "timely" => true,
          "lines" => [%{"jurisdiction" => "TX", "gross_cents" => 1_000_001, "exempt_cents" => 1, "returns_cents" => 100_000}]}
    {200, r} = call(:post, "/sales-tax/return", b)
    assert r["taxable_cents"] == 900_000 and r["tax_cents"] == 56_250
    assert r["vendor_discount_cents"] == 281 and r["net_due_cents"] == 56_250 - 281
    assert r["due_date"] == "2026-11-20"
    {200, r} = call(:post, "/sales-tax/return", %{b | "period" => "2026-09"} |> Map.delete("timely"))
    assert r["due_date"] == "2026-10-20"
    {200, r} = call(:post, "/sales-tax/return", %{b | "period" => "2026-12"})
    assert r["due_date"] == "2027-01-20"
    {422, e} = call(:post, "/sales-tax/return", %{b | "state" => "ZZ"})
    assert e["error"] == "unknown_state"
    {422, e} = call(:post, "/sales-tax/return", %{b | "period" => "2026-13"})
    assert e["error"] == "bad_period"
    {200, r} = call(:post, "/sales-tax/return", Map.put(b, "rates_bps", %{"ZZ" => 100}) |> Map.put("state", "ZZ"))
    assert r["tax_cents"] == 9_000
  end

  test "journal: balanced posting, rejection, trial balance, duplicates" do
    je = fn id, ent, amt ->
      %{"entity" => ent, "entry_id" => id,
        "lines" => [%{"account" => "1000", "debit_cents" => amt}, %{"account" => "4000", "credit_cents" => amt}]}
    end

    {200, v} = call(:post, "/erp/journal/validate", je.("v1", "E1", 500))
    assert v["valid"] and v["debit_total_cents"] == 500
    {201, _} = call(:post, "/erp/journal", je.("j1", "E1", 1_000))
    {201, _} = call(:post, "/erp/journal", je.("j2", "E2", 250))
    {409, d} = call(:post, "/erp/journal", je.("j1", "E1", 1_000))
    assert d["error"] == "duplicate_entry"

    {422, u} = call(:post, "/erp/journal", %{"entity" => "E1", "entry_id" => "j3",
      "lines" => [%{"account" => "1000", "debit_cents" => 10}, %{"account" => "4000", "credit_cents" => 9}]})
    assert u["error"] == "unbalanced_entry" and u["detail"] == %{"debits" => 10, "credits" => 9}
    {422, u} = call(:post, "/erp/journal", %{"entity" => "E1", "entry_id" => "j4",
      "lines" => [%{"account" => "9999", "debit_cents" => 10}, %{"account" => "4000", "credit_cents" => 10}]})
    assert u["error"] == "unknown_account"

    {200, tb} = call(:get, "/erp/trial-balance?entity=E1")
    assert tb["balanced"] and tb["debit_total_cents"] == 1_000
    {200, all} = call(:get, "/erp/trial-balance")
    assert all["debit_total_cents"] == 1_250 and all["credit_total_cents"] == 1_250
    {200, gl} = call(:get, "/erp/gl/accounts")
    assert Enum.any?(gl["accounts"], &(&1["id"] == "1300"))
  end

  test "ar/ap sync: idempotent upsert, cursor, aging" do
    recs = [
      %{"external_id" => "I1", "counterparty" => "C1", "amount_cents" => 10_000, "due_date" => "2026-08-01", "status" => "open"},
      %{"external_id" => "I2", "counterparty" => "C2", "amount_cents" => 5_000, "due_date" => "2026-11-30", "status" => "open"}
    ]

    body = %{"entity" => "E1", "kind" => "ar", "records" => recs}
    {200, a} = call(:post, "/erp/arap/sync", body)
    assert %{"created" => 2, "updated" => 0, "unchanged" => 0, "cursor" => 1} = a
    {200, a} = call(:post, "/erp/arap/sync", body)
    assert %{"created" => 0, "unchanged" => 2, "cursor" => 1} = a
    paid = [%{hd(recs) | "status" => "paid"}]
    {200, a} = call(:post, "/erp/arap/sync", %{body | "records" => paid})
    assert %{"updated" => 1, "cursor" => 2} = a
    {200, g} = call(:get, "/erp/arap/E1/ar?asOf=2026-11-14")
    assert g["open_balance_cents"] == 5_000 and g["aging"]["current"] == 5_000 and g["open_count"] == 1
    {400, _} = call(:post, "/erp/arap/sync", %{body | "kind" => "xx"})
  end

  test "swar: full mask admits; missing bit refuses with 0xE300 code" do
    {200, r} = call(:post, "/swar/admit", %{"mask" => 0xFFFF})
    assert r["admitted"] == true
    {200, r} = call(:post, "/swar/admit", %{"mask" => 0xFFFF - 0x10})
    assert r["admitted"] == false and r["refusal_code"] == 0xE300 + 4 and r["missing_gates"] == ["IRS_TIN_MATCHED"]
    gates = Smalt.Gatemask.gates() |> Enum.reject(&(&1 == "OFAC_BOI_CLEAR"))
    {200, r} = call(:post, "/swar/admit", %{"gates" => gates})
    assert r["refusal_code"] == 0xE300 + 3
    {400, _} = call(:post, "/swar/admit", %{"gates" => ["NOPE"]})
    {200, g} = call(:get, "/swar/gates")
    assert length(g["gates"]) == 16
  end
end
