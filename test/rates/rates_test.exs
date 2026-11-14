defmodule Smalt.RatesTest do
  use ExUnit.Case, async: true
  alias Smalt.Rates.{NyFed, Fred, Edgar, OpenCorporates, AbsPool}

  test "nyfed refRates shape and latest bps" do
    %{"refRates" => [r | _]} = NyFed.ref_rates(:sofr)
    assert r["type"] == "SOFR" and r["effectiveDate"] == "2026-11-13"
    assert NyFed.latest_bps(:sofr) == 430
    assert NyFed.latest_bps(:effr) == 433
  end

  test "fred observations" do
    {:ok, o} = Fred.observations("SOFR")
    assert o["count"] == 4 and hd(o["observations"])["value"] == "4.31"
    assert {:error, %{"error_code" => 400}} = Fred.observations("NOPE")
  end

  test "edgar" do
    {:ok, s} = Edgar.submissions(320_193)
    assert s["cik"] == "0000320193"
    {:ok, f} = Edgar.company_facts(320_193)
    assert f["facts"]["us-gaap"]["Assets"]["units"]["USD"] != []
    assert {:error, :not_found} = Edgar.submissions(1)
  end

  test "opencorporates tree" do
    {:ok, t} = OpenCorporates.tree()
    assert length(t["children"]) == 2
    assert {:ok, ["US-002", "US-003", "GB-101"]} = OpenCorporates.descendants()
  end

  test "abs pool balances and tranche pricing" do
    pool = AbsPool.pool("P1", 100_000_001, 7)
    assert AbsPool.balanced?(pool)
    rows = AbsPool.price(pool, [{"A", 8_000, 120}, {"B", 1_500, 300}, {"C", 500, 600}])
    assert Enum.sum(Enum.map(rows, & &1["principal_cents"])) == 100_000_001
    assert hd(rows)["coupon_bps"] == 430 + 120
    assert_raise ArgumentError, fn -> AbsPool.price(pool, [{"A", 9_000, 1}]) end
  end

  test "tranche interest reconciles to pool-level interest; remainder to last" do
    pool = AbsPool.pool("P2", 100_000_001, 7)
    rows = AbsPool.price(pool, [{"A", 3_333, 121}, {"B", 3_333, 307}, {"C", 3_334, 599}], 431)
    total = Enum.sum(for r <- rows, do: r["principal_cents"] * r["coupon_bps"])
    assert Enum.sum(Enum.map(rows, & &1["monthly_interest_cents"])) == div(total, 120_000)
  end

  test "balanced? false on mismatch and malformed" do
    refute AbsPool.balanced?(%{"principal_cents" => 100, "receivables" => [%{"principal_cents" => 50}]})
    refute AbsPool.balanced?(%{"principal_cents" => 100, "receivables" => "x"})
    refute AbsPool.balanced?(:nope)
  end
end
