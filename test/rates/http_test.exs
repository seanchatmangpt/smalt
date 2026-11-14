defmodule Smalt.Rates.HttpTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Smalt.Rates.Http

  defp get_json(path) do
    conn = Http.call(conn(:get, path), Http.init([]))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp post_json(path, body) do
    conn =
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Http.call(Http.init([]))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "sofr last 1" do
    assert {200, %{"refRates" => [%{"type" => "SOFR", "effectiveDate" => "2026-11-13"}]}} =
             get_json("/markets/refrates/secured/sofr/last/1.json")
  end

  test "fred observations ok and 400" do
    assert {200, %{"count" => 4}} = get_json("/fred/series/observations?series_id=SOFR")
    assert {400, %{"error_code" => 400}} = get_json("/fred/series/observations?series_id=NOPE")
  end

  test "edgar submissions and facts" do
    assert {200, %{"cik" => "0000320193"}} = get_json("/submissions/CIK0000320193.json")
    assert {404, _} = get_json("/submissions/CIK0000000001.json")
    assert {200, %{"entityName" => "Example Holdings Inc."}} = get_json("/api/facts/CIK0000320193.json")
  end

  test "opencorporates tree" do
    assert {200, %{"results" => %{"tree" => %{"children" => [_, _]}}}} =
             get_json("/opencorporates/companies/us/001/tree")

    assert {404, _} = get_json("/opencorporates/companies/us/999/tree")
  end

  test "abs pool then price" do
    {200, pool} = post_json("/abs/pool", %{"pool_id" => "P1", "principal_cents" => 1_000_001, "n" => 3})
    assert Smalt.Rates.AbsPool.balanced?(pool)

    {200, %{"tranches" => [a, b]}} =
      post_json("/abs/price", %{
        "pool" => pool,
        "sofr_bps" => 430,
        "tranches" => [
          %{"name" => "A", "share_bps" => 8000, "spread_bps" => 100},
          %{"name" => "B", "share_bps" => 2000, "spread_bps" => 300}
        ]
      })

    assert a["coupon_bps"] == 530 and b["coupon_bps"] == 730
    assert a["principal_cents"] + b["principal_cents"] == 1_000_001

    assert {422, _} = post_json("/abs/pool", %{"n" => 0})
  end
end
