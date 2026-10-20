# C16 ERRC-RAISE lane (v26.10.19 window): KQL-subset raise — summarize/project
# renames+computed/ago()/between/take/sort+nulls/extend/has, typed SYN- parse
# errors with byte position, fail-closed on unknown operators. Chicago-style:
# real rows, assert on final state; no mocks.
defmodule DataPlane.KqlRaiseTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.KQL
  alias Smalt.DataPlane.Sentinel
  alias Smalt.Store

  @ts DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1800, :second))

  defp rows do
    for i <- 1..10 do
      %{
        "TimeGenerated" => @ts,
        "Level" => if(rem(i, 3) == 0, do: "Error", else: "Info"),
        "Dur" => i * 10
      }
    end
  end

  # -- engine-level: aggregation, projection, time functions -------------------

  test "witness: where ago -> summarize count by Level -> sort count_ desc" do
    assert {:ok,
            [
              %{"Level" => "Info", "count_" => 7},
              %{"Level" => "Error", "count_" => 3}
            ]} =
             KQL.run(
               rows(),
               "| where TimeGenerated > ago(1h) | summarize count() by Level | sort by count_ desc"
             )
  end

  test "summarize sum/avg/min/max without by" do
    assert {:ok, [%{"sum_Dur" => 140, "avg_Dur" => 35.0, "min_Dur" => 20, "max_Dur" => 50}]} =
             KQL.run(
               rows(),
               "| where Dur between (20 .. 50) | summarize sum(Dur), avg(Dur), min(Dur), max(Dur)"
             )
  end

  test "extend computed column, project rename, take" do
    assert {:ok,
            [
              %{"Half" => 5.0, "Lvl" => "Info"},
              %{"Half" => 10.0, "Lvl" => "Info"}
            ]} =
             KQL.run(
               rows(),
               "| extend Half = Dur / 2 | project Lvl = Level, Half | take 2"
             )
  end

  test "sort desc nulls last places missing rows after present ones" do
    sparse = rows() ++ [%{"Level" => "X", "Dur" => 5}, %{"Level" => "Y"}]

    assert {:ok, out} = KQL.run(sparse, "| sort by Dur desc nulls last")
    assert length(out) == 12
    assert %{"Level" => "Y"} = List.last(out)
    refute Map.has_key?(List.last(out), "Dur")
    assert %{"Dur" => 100} = List.first(out)
  end

  test "has matches whole terms, contains matches substrings" do
    assert {:ok, r1} = KQL.run(rows(), "| where Level has \"Error\"")
    assert length(r1) == 3
    assert {:ok, []} = KQL.run(rows(), "| where Level has \"Err\"")

    assert {:ok, r2} = KQL.run(rows(), "| where Level contains \"err\" and Dur > 30")
    assert length(r2) == 2
  end

  test "datetime between with ago/now bounds" do
    assert {:ok, r} =
             KQL.run(rows(), "| where TimeGenerated between (ago(2h) .. now()) | take 1")

    assert length(r) == 1
  end

  # -- typed SYN- parse errors (fail-closed) -------------------------------------

  test "unknown operators/aggregates/functions are typed parse errors with position" do
    for q <- [
          "| frobnicate x",
          "| summarize frobnicate(Dur) by Level",
          "| summarize count() by Level | frobnicate2"
        ] do
      assert {:error, {:parse, "SYN0004: " <> _}} = KQL.run(rows(), q)
    end

    # unknown function in a where predicate: the parser sees a bare column
    # first, so the failure is the typed comparison-operand error (SYN0003) —
    # still fail-closed, never silent
    assert {:error, {:parse, "SYN0003: " <> _}} = KQL.run(rows(), "| where frobnicate(1h)")

    assert {:error, {:parse, "SYN0004: unknown pipeline operator \"frobnicate\" (position 2)"}} =
             KQL.run(rows(), "| frobnicate x")
  end

  test "truncated queries are typed operand errors" do
    assert {:error, {:parse, "SYN0003: " <> _}} = KQL.run(rows(), "| where Level == ")
    assert {:error, {:parse, "SYN0003: " <> _}} = KQL.run(rows(), "| summarize sum(")
  end

  test "malformed clauses are typed unexpected errors" do
    assert {:error, {:parse, "SYN0002: " <> _}} = KQL.run(rows(), "| sort by Dur nulls sideways")
    assert {:error, {:parse, "SYN0003: " <> _}} = KQL.run(rows(), "| take notanumber")
  end

  # -- sentinel plane: DCR rows carry TimeGenerated; query routes end to end -----

  test "sentinel: DCR-ingested rows resolve ago() through the query pipeline" do
    dcr = "dcr-c16-#{System.unique_integer([:positive])}"
    Sentinel.ingest(dcr, "s1", rows(), "2023-01-01")

    assert {:ok, 200, %{"tables" => [table]}} =
             Sentinel.query(dcr, %{
               "query" =>
                 "| where TimeGenerated > ago(1h) | summarize count() by Level | sort by count_ desc"
             })

    assert %{"name" => "PrimaryResult", "columns" => cols, "rows" => rws} = table
    names = Enum.map(cols, & &1["name"])
    assert names == ["Level", "count_"]

    assert Enum.sort(rws) == [
             ["Error", "3"],
             ["Info", "7"]
           ]

    # legacy path untouched: bare take N still rides the non-pipeline route
    assert {:ok, 200, %{"tables" => [t2]}} = Sentinel.query(dcr, %{"query" => "take 3"})
    assert length(t2["rows"]) == 3
  end

  test "sentinel: bare pipeline operator without pipe is a typed 400" do
    dcr2 = "dcr-c16-#{System.unique_integer([:positive])}"
    Sentinel.ingest(dcr2, "s2", rows(), "2023-01-01")

    assert {:error, 400, %{"error" => %{"code" => "BadQuery"}}} =
             Sentinel.query(dcr2, %{"query" => "summarize count() by Level"})
  end
end
