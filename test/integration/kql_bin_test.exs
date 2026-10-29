# Integration-tier witness (T-05 increment 1, v26.10.28): KQL bin() —
# `summarize ... by bin(Col, <timespan>|<number>)` bucketing, court-tested
# through the engine the Sentinel/KQL plane rides (Smalt.DataPlane.KQL).
#
# Chicago discipline: real parser + real eval over fixed row corpora; typed
# SYN- refusals for malformed bin() shapes (fail-closed law).

defmodule Smalt.Internal.KqlBinTest do
  use ExUnit.Case, async: true

  alias Smalt.DataPlane.KQL

  # Fixed corpus: ISO-string TimeGenerated values straddling two 5-minute
  # buckets (12:01, 12:03 -> 12:00 bucket; 12:07 -> 12:05 bucket), plus a
  # numeric column for numeric binning.
  @rows [
    %{"TimeGenerated" => "2026-10-28T12:01:00Z", "tenantId" => "a", "Load" => 7},
    %{"TimeGenerated" => "2026-10-28T12:03:30Z", "tenantId" => "b", "Load" => 2},
    %{"TimeGenerated" => "2026-10-28T12:07:00Z", "tenantId" => "a", "Load" => 5}
  ]

  test "by bin(TimeGenerated, 5m) buckets to 5-minute bucket starts" do
    assert {:ok, rows} = KQL.run(@rows, "| summarize count() by bin(TimeGenerated, 5m)")

    buckets =
      Map.new(rows, fn row ->
        {DateTime.to_iso8601(row["TimeGenerated"]), row["count_"]}
      end)

    assert buckets == %{
             "2026-10-28T12:00:00.000Z" => 2,
             "2026-10-28T12:05:00.000Z" => 1
           }
  end

  test "bin() composes with a plain by-column and other aggregates" do
    assert {:ok, rows} =
             KQL.run(@rows, "| summarize count(), sum(Load) by tenantId, bin(TimeGenerated, 1h)")

    by_group =
      Map.new(rows, fn row ->
        {{row["tenantId"], DateTime.to_iso8601(row["TimeGenerated"])}, row["count_"]}
      end)

    # Everything lands in the 12:00 1-hour bucket.
    assert by_group == %{{"a", "2026-10-28T12:00:00.000Z"} => 2, {"b", "2026-10-28T12:00:00.000Z"} => 1}

    assert Enum.any?(rows, fn row -> Map.get(row, "sum_Load") == 12 end)
  end

  test "numeric bin floors to step multiples" do
    assert {:ok, rows} = KQL.run(@rows, "| summarize count() by bin(Load, 5)")
    floors = Map.new(rows, fn row -> {row["Load"], row["count_"]} end)
    assert Map.get(floors, 5.0) == 2
    assert Map.get(floors, 0.0) == 1
  end

  test "%DateTime{} rows bucket identically to ISO-string rows" do
    dt_rows =
      Enum.map(@rows, fn row ->
        {:ok, dt, _} = DateTime.from_iso8601(row["TimeGenerated"])
        %{row | "TimeGenerated" => dt}
      end)

    assert {:ok, rows} = KQL.run(dt_rows, "| summarize count() by bin(TimeGenerated, 5m)")
    counts = Enum.sort(Enum.map(rows, & &1["count_"]))
    assert counts == [1, 2]
  end

  # -- fail-closed: malformed bin() shapes are typed SYN- parse errors --------

  test "invalid step refuses SYN0002" do
    assert {:error, {:parse, msg}} = KQL.run(@rows, "| summarize count() by bin(TimeGenerated, 5x)")
    assert msg =~ "SYN0002"
    assert msg =~ "invalid bin() step"
  end

  test "unterminated bin() refuses SYN0002" do
    assert {:error, {:parse, msg}} = KQL.run(@rows, "| summarize count() by bin(TimeGenerated")
    assert msg =~ "SYN0002"
  end

  test "bin() without a comma refuses SYN0002" do
    assert {:error, {:parse, msg}} = KQL.run(@rows, "| summarize count() by bin(TimeGenerated 5m)")
    assert msg =~ "SYN0002"
  end
end
