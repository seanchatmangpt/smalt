defmodule Smalt.H08.RatesTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Smalt.Rates.Http
  alias Smalt.H08.AbsTape

  defp get(path) do
    c = Http.call(conn(:get, path), Http.init([]))
    {c.status, Jason.decode!(c.resp_body)}
  end

  defp post(path, body) do
    c = conn(:post, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json") |> Http.call(Http.init([]))
    {c.status, Jason.decode!(c.resp_body)}
  end

  test "nyfed last/N and search in real shape" do
    assert {200, %{"refRates" => [a, b]}} = get("/api/rates/secured/sofr/last/2.json")
    assert a["effectiveDate"] == "2026-11-13" and b["effectiveDate"] == "2026-11-12" and a["type"] == "SOFR"
    assert {200, %{"refRates" => rows}} = get("/api/rates/secured/sofr/search.json?startDate=2026-11-11&endDate=2026-11-12")
    assert Enum.map(rows, & &1["effectiveDate"]) == ["2026-11-12", "2026-11-11"]
    assert {200, %{"refRates" => [%{"type" => "EFFR"}]}} = get("/api/rates/unsecured/effr/last/1.json")
    assert {400, %{"error" => _}} = get("/api/rates/secured/sofr/last/0.json")
    assert {400, _} = get("/api/rates/secured/sofr/search.json")
  end

  test "sofr curve points are [days, zero_bps] with monotone discount factors" do
    assert {200, %{"spot_bps" => 430, "points" => [[30, 428] | _] = pts, "discount_factors" => dfs}} = get("/h08/sofr/curve")
    assert length(pts) == 7
    assert hd(dfs)["df_ppb"] in (div(1_000_000_000 * 3_600_000, 3_612_840) - 1)..(div(1_000_000_000 * 3_600_000, 3_612_840) + 1)
    ppb = Enum.map(dfs, & &1["df_ppb"])
    assert ppb == Enum.sort(ppb, :desc)
  end

  test "sofr compounded average over the published series" do
    assert {200, %{"observations" => 4, "accrual_days" => 4, "average_percent_x10000" => avg}} =
             get("/h08/sofr/average?start=2026-11-10&end=2026-11-13")

    assert avg in 43_199..43_202
    assert {404, %{"error" => "no_data"}} = get("/h08/sofr/average?start=2030-01-01&end=2030-01-02")
    assert {400, _} = get("/h08/sofr/average?start=2026-11-13&end=2026-11-10")
  end

  test "abs tape: sums, strats, level payment, stored, conflict on repost" do
    id = "pool-h08-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {201, t} = post("/h08/abs/tape", %{"pool_id" => id, "principal_cents" => 100_000_000, "n" => 10, "as_of" => "2026-11-14"})
    assert Enum.sum(Enum.map(t["loans"], & &1["principal_cents"])) == 100_000_000
    assert t["summary"]["wac_bps"] == 1419 and t["summary"]["wam_months"] == 46
    assert Enum.at(t["loans"], 1)["origination_month"] == "2026-08"
    assert t["summary"]["scheduled_payment_cents"] == Enum.sum(Enum.map(t["loans"], & &1["payment_cents"]))
    assert {200, ^t} = get("/h08/abs/tape/#{id}")
    assert {409, _} = post("/h08/abs/tape", %{"pool_id" => id, "principal_cents" => 1, "n" => 1, "as_of" => "2026-11-14"})
    assert {404, _} = get("/h08/abs/tape/absent")
    assert {422, _} = post("/h08/abs/tape", %{"pool_id" => id})
  end

  test "level payment: 10000.00 at 12% over 12 months is 888.49" do
    assert AbsTape.payment(1_000_000, 1200, 12) == 88_849
  end
end
